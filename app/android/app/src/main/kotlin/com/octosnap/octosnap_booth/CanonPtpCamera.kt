package com.octosnap.octosnap_booth

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Minimal PTP-over-USB driver for Canon EOS cameras (tested target: EOS R10).
 * Implements: open session, Canon remote mode, capture-to-host, EVF live view.
 */
class CanonPtpCamera private constructor(
    private val manager: UsbManager,
    private val device: UsbDevice,
    private val conn: UsbDeviceConnection,
    private val intf: UsbInterface,
    private val epIn: UsbEndpoint,
    private val epOut: UsbEndpoint,
) {
    val name: String = listOfNotNull(device.manufacturerName, device.productName).joinToString(" ").ifBlank { "Canon camera" }
    private var txId = 0
    private var liveOn = false
    private val seenHandles = HashSet<Int>()

    companion object {
        private const val ACTION_PERMISSION = "com.octosnap.USB_PERMISSION"
        private const val CANON_VID = 0x04A9
        private const val TIMEOUT = 5000

        // PTP container types
        private const val T_COMMAND = 1
        private const val T_DATA = 2
        private const val T_RESPONSE = 3

        // Operation / response codes
        private const val OP_OPEN_SESSION = 0x1002
        private const val OP_CLOSE_SESSION = 0x1003
        private const val OP_GET_OBJECT = 0x1009
        private const val OP_EOS_SET_PROP = 0x9110
        private const val OP_EOS_REMOTE_RELEASE = 0x910F
        private const val OP_EOS_SET_REMOTE_MODE = 0x9114
        private const val OP_EOS_SET_EVENT_MODE = 0x9115
        private const val OP_EOS_GET_EVENT = 0x9116
        private const val OP_EOS_TRANSFER_COMPLETE = 0x9117
        private const val OP_EOS_PC_HDD_CAPACITY = 0x911A
        private const val OP_EOS_RELEASE_ON = 0x9128
        private const val OP_EOS_RELEASE_OFF = 0x9129
        private const val OP_EOS_VIEWFINDER = 0x9153

        private const val RC_OK = 0x2001
        private const val RC_SESSION_OPEN = 0x201E
        private const val RC_DEVICE_BUSY = 0x2019
        private const val RC_NOT_READY = 0xA102

        private const val PROP_CAPTURE_DEST = 0xD11C
        private const val PROP_EVF_OUTPUT = 0xD1B0
        private const val PROP_EVF_MODE = 0xD1B3
        private const val EV_OBJECT_ADDED = 0xC181
        private const val EV_OBJECT_ADDED64 = 0xC1A7
        private const val EV_REQUEST_TRANSFER = 0xC186
        private const val EV_REQUEST_TRANSFER64 = 0xC1A9
        private const val EV_STD_OBJECT_ADDED = 0x4002
        // Object formats that are never JPEG (skip download): CR2, CRW, CR3, MOV/MP4
        private val SKIP_FORMATS = setOf(0xB103, 0xB101, 0xB108, 0x300D, 0xB982)

        /** Finds the camera, asks USB permission if needed, opens a PTP session. */
        fun open(ctx: Context): CanonPtpCamera {
            val mgr = ctx.getSystemService(Context.USB_SERVICE) as UsbManager
            val devices = mgr.deviceList.values
            val dev = devices.firstOrNull { it.vendorId == CANON_VID && findPtp(it) != null }
                ?: devices.firstOrNull { findPtp(it) != null }
                ?: throw IllegalStateException("No camera found on USB. Check cable, OTG and that the camera is ON.")
            if (!mgr.hasPermission(dev)) askPermission(ctx, mgr, dev)
            if (!mgr.hasPermission(dev)) throw IllegalStateException("USB permission denied")
            val intf = findPtp(dev)!!
            var inEp: UsbEndpoint? = null
            var outEp: UsbEndpoint? = null
            for (i in 0 until intf.endpointCount) {
                val ep = intf.getEndpoint(i)
                if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
                if (ep.direction == UsbConstants.USB_DIR_IN) inEp = ep else outEp = ep
            }
            if (inEp == null || outEp == null) throw IllegalStateException("Camera has no bulk endpoints")
            val info = "VID %04X PID %04X, intf %d, out 0x%02X/%d, in 0x%02X/%d".format(
                dev.vendorId, dev.productId, intf.id, outEp.address, outEp.maxPacketSize, inEp.address, inEp.maxPacketSize)
            // Up to 3 attempts: a camera left mid-transaction (app killed, earlier error) has its
            // pipes stalled; a PTP device reset + clear-halt and a fresh connection recovers it.
            var last: Exception? = null
            for (attempt in 1..3) {
                val conn = mgr.openDevice(dev) ?: throw IllegalStateException("Could not open USB device")
                if (!conn.claimInterface(intf, true)) {
                    conn.close()
                    throw IllegalStateException("Camera is busy (close other camera / gallery import apps)")
                }
                resetPipes(conn, intf, inEp, outEp, hard = attempt > 1)
                val cam = CanonPtpCamera(mgr, dev, conn, intf, inEp, outEp)
                try {
                    cam.init()
                    return cam
                } catch (e: Exception) {
                    last = e
                    try { conn.releaseInterface(intf) } catch (_: Exception) {}
                    try { conn.close() } catch (_: Exception) {}
                    Thread.sleep(700L * attempt)
                }
            }
            throw IllegalStateException("${last?.message} [$info]")
        }

        private fun resetPipes(c: UsbDeviceConnection, intf: UsbInterface, epIn: UsbEndpoint, epOut: UsbEndpoint, hard: Boolean) {
            if (hard) {
                // PTP class request "Device Reset" (0x66)
                c.controlTransfer(0x21, 0x66, 0, intf.id, null, 0, 2000)
                Thread.sleep(300)
            }
            // CLEAR_FEATURE(ENDPOINT_HALT) on both bulk pipes
            c.controlTransfer(0x02, 0x01, 0, epOut.address, null, 0, 1000)
            c.controlTransfer(0x02, 0x01, 0, epIn.address, null, 0, 1000)
            // drain anything stale the camera still wants to send
            val junk = ByteArray(epIn.maxPacketSize.coerceAtLeast(512) * 8)
            var i = 0
            while (i++ < 4 && c.bulkTransfer(epIn, junk, junk.size, 100) > 0) {}
        }

        private fun findPtp(d: UsbDevice): UsbInterface? {
            for (i in 0 until d.interfaceCount) {
                val f = d.getInterface(i)
                if (f.interfaceClass == UsbConstants.USB_CLASS_STILL_IMAGE) return f
            }
            return null
        }

        private fun askPermission(ctx: Context, mgr: UsbManager, dev: UsbDevice) {
            val latch = CountDownLatch(1)
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, i: Intent) { latch.countDown() }
            }
            val filter = IntentFilter(ACTION_PERMISSION)
            if (Build.VERSION.SDK_INT >= 33) {
                ctx.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                ctx.registerReceiver(receiver, filter)
            }
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(ctx, 0, Intent(ACTION_PERMISSION).setPackage(ctx.packageName), flags)
            mgr.requestPermission(dev, pi)
            latch.await(60, TimeUnit.SECONDS)
            try { ctx.unregisterReceiver(receiver) } catch (_: Exception) {}
        }
    }

    fun isAttached(): Boolean = manager.deviceList.values.any { it.deviceName == device.deviceName }

    private fun init() {
        val rc = transaction(OP_OPEN_SESSION, intArrayOf(1)).code
        if (rc != RC_OK && rc != RC_SESSION_OPEN) throw IllegalStateException("OpenSession failed 0x%04X".format(rc))
        transaction(OP_EOS_SET_REMOTE_MODE, intArrayOf(1))
        transaction(OP_EOS_SET_EVENT_MODE, intArrayOf(1))
        drainEvents()
        // Save captures to the host (RAM), not only the SD card.
        setProp(PROP_CAPTURE_DEST, 4)
        transaction(OP_EOS_PC_HDD_CAPACITY, intArrayOf(0x0fffffff, 0x00001000, 0x00000001))
        drainEvents()
    }

    fun startLiveView() {
        setProp(PROP_EVF_MODE, 1)
        setProp(PROP_EVF_OUTPUT, 2) // 2 = PC
        liveOn = true
    }

    /** One JPEG live-view frame, or null when the camera is not ready yet. */
    fun liveViewFrame(): ByteArray? {
        if (!liveOn) startLiveView()
        val r = transaction(OP_EOS_VIEWFINDER, intArrayOf(0x00200000, 0, 0))
        if (r.code == RC_NOT_READY || r.code == RC_DEVICE_BUSY) return null
        if (r.code != RC_OK) throw IllegalStateException("Live view error 0x%04X".format(r.code))
        val d = r.data ?: return null
        // Records: [u32 length][u32 type][payload]; type 1 = JPEG
        var off = 0
        while (off + 8 <= d.size) {
            val len = u32(d, off)
            val type = u32(d, off + 4)
            if (len < 8 || off + len > d.size) break
            if (type == 1) return d.copyOfRange(off + 8, off + len)
            off += len
        }
        return findJpeg(d)
    }

    /** Fires the shutter and returns the JPEG the camera sends to the host. */
    fun capture(): ByteArray {
        drainEvents()
        var rc = transaction(OP_EOS_RELEASE_ON, intArrayOf(3, 0)).code
        if (rc == RC_OK) {
            transaction(OP_EOS_RELEASE_OFF, intArrayOf(3))
        } else {
            rc = transaction(OP_EOS_REMOTE_RELEASE, intArrayOf()).code
            if (rc != RC_OK) throw IllegalStateException("Shutter failed 0x%04X (check focus / lens / SD card)".format(rc))
        }
        val deadline = System.currentTimeMillis() + 15000
        while (System.currentTimeMillis() < deadline) {
            val jpeg = downloadNew()
            if (jpeg != null) { resumeLiveView(); return jpeg }
            Thread.sleep(80)
        }
        throw IllegalStateException("Camera took the photo but sent no JPEG (set image quality to JPEG, not RAW only)")
    }

    /**
     * Shutter pressed ON THE CAMERA: polls Canon events once and, if the camera added a new
     * photo (sent to the host because capture destination = PC), downloads and returns the JPEG.
     * Returns null when nothing new. Live view is re-enabled afterwards.
     */
    fun pollExternal(): ByteArray? {
        val jpeg = downloadNew() ?: return null
        resumeLiveView()
        return jpeg
    }

    private fun resumeLiveView() {
        if (!liveOn) return
        try {
            setProp(PROP_EVF_MODE, 1)
            setProp(PROP_EVF_OUTPUT, 2)
        } catch (_: Exception) {}
    }

    /** Downloads every new object from one GetEvent poll; returns the last JPEG among them. */
    private fun downloadNew(): ByteArray? {
        var jpeg: ByteArray? = null
        for ((handle, format) in newObjects()) {
            if (!seenHandles.add(handle)) continue
            if (format in SKIP_FORMATS) {
                try { transaction(OP_EOS_TRANSFER_COMPLETE, intArrayOf(handle)) } catch (_: Exception) {}
                continue
            }
            val obj = transaction(OP_GET_OBJECT, intArrayOf(handle))
            try { transaction(OP_EOS_TRANSFER_COMPLETE, intArrayOf(handle)) } catch (_: Exception) {}
            val bytes = obj.data
            if (obj.code == RC_OK && bytes != null && bytes.size > 2 &&
                bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) jpeg = bytes
        }
        return jpeg
    }

    fun close() {
        try {
            if (liveOn) setProp(PROP_EVF_OUTPUT, 0)
            transaction(OP_EOS_SET_REMOTE_MODE, intArrayOf(0))
            transaction(OP_CLOSE_SESSION, intArrayOf())
        } catch (_: Exception) {}
        try { conn.releaseInterface(intf) } catch (_: Exception) {}
        try { conn.close() } catch (_: Exception) {}
    }

    // ---------------------------------------------------------------- events

    private fun drainEvents() { try { transaction(OP_EOS_GET_EVENT, intArrayOf()) } catch (_: Exception) {} }

    /** (handle, objectFormat) of objects announced by one Canon GetEvent (0x9116) poll. */
    private fun newObjects(): List<Pair<Int, Int>> {
        val r = transaction(OP_EOS_GET_EVENT, intArrayOf())
        val d = r.data ?: return emptyList()
        val out = ArrayList<Pair<Int, Int>>()
        var off = 0
        while (off + 8 <= d.size) {
            val len = u32(d, off)
            val type = u32(d, off + 4)
            if (len < 8 || (len == 8 && type == 0) || off + len > d.size) break
            val isObj = type == EV_OBJECT_ADDED || type == EV_OBJECT_ADDED64 ||
                type == EV_REQUEST_TRANSFER || type == EV_REQUEST_TRANSFER64 || type == EV_STD_OBJECT_ADDED
            if (isObj && off + 12 <= d.size) {
                val handle = u32(d, off + 8)
                // ObjectAddedEx: format at +0x10; RequestObjectTransfer: at +0x0C (libgphoto2 layout)
                val fOff = if (type == EV_REQUEST_TRANSFER || type == EV_REQUEST_TRANSFER64) 12 else 16
                val format = if (len >= fOff + 2) u16(d, off + fOff) else 0
                if (out.none { it.first == handle }) out.add(handle to format)
            }
            off += len
        }
        return out
    }

    private fun setProp(prop: Int, value: Int) {
        val payload = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).putInt(12).putInt(prop).putInt(value).array()
        transaction(OP_EOS_SET_PROP, intArrayOf(), payload)
    }

    // ------------------------------------------------------------ transport

    private class Response(val code: Int, val data: ByteArray?)

    @Synchronized
    private fun transaction(op: Int, params: IntArray, outData: ByteArray? = null): Response {
        val id = ++txId
        val cmd = ByteBuffer.allocate(12 + 4 * params.size).order(ByteOrder.LITTLE_ENDIAN)
        cmd.putInt(12 + 4 * params.size).putShort(T_COMMAND.toShort()).putShort(op.toShort()).putInt(id)
        params.forEach { cmd.putInt(it) }
        write(cmd.array())
        if (outData != null) {
            val data = ByteBuffer.allocate(12 + outData.size).order(ByteOrder.LITTLE_ENDIAN)
            data.putInt(12 + outData.size).putShort(T_DATA.toShort()).putShort(op.toShort()).putInt(id).put(outData)
            write(data.array())
        }
        var received: ByteArray? = null
        while (true) {
            val c = readContainer()
            val type = u16(c, 4)
            when (type) {
                T_DATA -> received = c.copyOfRange(12, c.size)
                T_RESPONSE -> return Response(u16(c, 6), received)
                else -> {} // ignore unexpected containers
            }
        }
    }

    private fun write(b: ByteArray) {
        var off = 0
        while (off < b.size) {
            val len = minOf(b.size - off, 16384)
            val chunk = if (off == 0 && len == b.size) b else b.copyOfRange(off, off + len)
            val n = conn.bulkTransfer(epOut, chunk, len, TIMEOUT)
            if (n < 0) throw IllegalStateException("USB write failed at op 0x%04X (camera not answering)".format(u16(b, 6)))
            off += n
        }
        // A transfer that is an exact multiple of the packet size needs a zero-length packet.
        if (b.size % epOut.maxPacketSize == 0) conn.bulkTransfer(epOut, ByteArray(0), 0, TIMEOUT)
    }

    private fun readContainer(): ByteArray {
        val chunk = if (Build.VERSION.SDK_INT >= 28) 256 * 1024 else 16384
        val buf = ByteArray(chunk)
        var n: Int
        var tries = 0
        do {
            n = conn.bulkTransfer(epIn, buf, buf.size, TIMEOUT)
            if (n < 0) throw IllegalStateException("USB read failed (camera disconnected?)")
        } while (n == 0 && ++tries < 3) // skip stray zero-length packets
        if (n < 12) throw IllegalStateException("Short PTP packet")
        val total = u32(buf, 0)
        if (total <= n) return buf.copyOf(n)
        val out = ByteArrayOutputStream(total)
        out.write(buf, 0, n)
        var got = n
        while (got < total) {
            val m = conn.bulkTransfer(epIn, buf, minOf(buf.size, maxOf(total - got, epIn.maxPacketSize)), TIMEOUT)
            if (m < 0) throw IllegalStateException("USB read failed during transfer")
            out.write(buf, 0, m)
            got += m
        }
        return out.toByteArray()
    }

    private fun u32(b: ByteArray, o: Int): Int =
        (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8) or
            ((b[o + 2].toInt() and 0xFF) shl 16) or ((b[o + 3].toInt() and 0xFF) shl 24)

    private fun u16(b: ByteArray, o: Int): Int = (b[o].toInt() and 0xFF) or ((b[o + 1].toInt() and 0xFF) shl 8)

    private fun findJpeg(d: ByteArray): ByteArray? {
        for (i in 0 until d.size - 1) {
            if (d[i] == 0xFF.toByte() && d[i + 1] == 0xD8.toByte()) return d.copyOfRange(i, d.size)
        }
        return null
    }
}
