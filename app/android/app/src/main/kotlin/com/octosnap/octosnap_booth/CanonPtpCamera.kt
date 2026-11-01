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
            val conn = mgr.openDevice(dev) ?: throw IllegalStateException("Could not open USB device")
            if (!conn.claimInterface(intf, true)) {
                conn.close()
                throw IllegalStateException("Camera is busy (close other camera apps)")
            }
            val cam = CanonPtpCamera(mgr, dev, conn, intf, inEp, outEp)
            try {
                cam.init()
            } catch (e: Exception) {
                cam.close()
                throw e
            }
            return cam
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
        var jpeg: ByteArray? = null
        while (System.currentTimeMillis() < deadline) {
            for (handle in newObjects()) {
                val obj = transaction(OP_GET_OBJECT, intArrayOf(handle))
                transaction(OP_EOS_TRANSFER_COMPLETE, intArrayOf(handle))
                val bytes = obj.data
                if (obj.code == RC_OK && bytes != null && bytes.size > 2 &&
                    bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte()) jpeg = bytes
            }
            if (jpeg != null) return jpeg
            Thread.sleep(80)
        }
        throw IllegalStateException("Camera took the photo but sent no JPEG (set image quality to JPEG, not RAW only)")
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

    private fun newObjects(): List<Int> {
        val r = transaction(OP_EOS_GET_EVENT, intArrayOf())
        val d = r.data ?: return emptyList()
        val out = ArrayList<Int>()
        var off = 0
        while (off + 8 <= d.size) {
            val len = u32(d, off)
            val type = u32(d, off + 4)
            if (len < 8 || (len == 8 && type == 0)) break
            if ((type == EV_OBJECT_ADDED || type == EV_OBJECT_ADDED64) && off + 12 <= d.size) out.add(u32(d, off + 8))
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
            val n = conn.bulkTransfer(epOut, b, off, minOf(b.size - off, 16384), TIMEOUT)
            if (n < 0) throw IllegalStateException("USB write failed (camera disconnected?)")
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
