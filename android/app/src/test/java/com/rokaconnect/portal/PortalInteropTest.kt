package com.rokaconnect.portal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Talks to a running Mac (set PORTAL_CODE; optional PORTAL_HOST). Skipped when PORTAL_CODE is unset. */
class PortalInteropTest {
    private val code = System.getenv("PORTAL_CODE") ?: ""
    private val host = System.getenv("PORTAL_HOST") ?: "127.0.0.1"
    private fun header(kind: String, name: String, size: Long) =
        """{"kind":"$kind","name":"$name","size":$size,"transition":"classic","ts":${System.currentTimeMillis() / 1000.0},"from":"Interop test","platform":"android"}""".toByteArray()

    @Test fun wrongCodeIsRejected() {
        assumeTrue(code.isNotEmpty())
        val ok = runCatching {
            PortalConnection(host, Portal.PORT, Portal.deriveKey("AAAABBBBCCCC")).use { c -> c.sendFrame(header("list", "", 0)); c.recvFrame() }
        }.isSuccess
        assertTrue("a wrong code must not get an answer", !ok)
    }

    @Test fun listAndUpload() {
        assumeTrue(code.isNotEmpty())
        val key = Portal.deriveKey(code)
        PortalConnection(host, Portal.PORT, key).use { c ->
            c.sendFrame(header("list", "", 0))
            val reply = String(c.recvFrame())
            println("list -> $reply")
            assertTrue(reply.contains("\"files\""))
        }
        val data = ByteArray(2_500_000) { (it * 31 % 251).toByte() }
        PortalConnection(host, Portal.PORT, key).use { c ->
            c.sendFrame(header("file", "android-interop-test.bin", data.size.toLong()))
            var i = 0
            while (i < data.size) { val n = minOf(Portal.CHUNK, data.size - i); c.sendFrame(data, i, n); i += n }
            assertEquals("OK", String(c.recvFrame()))
        }
        val saved = java.io.File(System.getProperty("user.home"), "Downloads/Rokaconnect/android-interop-test.bin")
        assertTrue("file saved on Mac", saved.exists())
        assertTrue("file identical", saved.readBytes().contentEquals(data))
        saved.delete()
    }
}

class PortalDownloadTest {
    @Test fun downloadOffered() {
        val code = System.getenv("PORTAL_CODE") ?: ""
        val expected = System.getenv("PORTAL_OFFER") ?: ""
        assumeTrue(code.isNotEmpty() && expected.isNotEmpty())
        val h = """{"kind":"get","name":"0","size":0,"transition":"classic","ts":${System.currentTimeMillis() / 1000.0},"from":"Interop test","platform":"android"}"""
        PortalConnection("127.0.0.1", Portal.PORT, Portal.deriveKey(code)).use { c ->
            c.sendFrame(h.toByteArray())
            val meta = String(c.recvFrame()); println("get -> $meta")
            val size = Regex("\"size\":(\\d+)").find(meta)!!.groupValues[1].toLong()
            val out = java.io.ByteArrayOutputStream()
            while (out.size() < size) out.write(c.recvFrame())
            c.sendFrame("OK".toByteArray())
            assertTrue("download identical", out.toByteArray().contentEquals(java.io.File(expected).readBytes()))
        }
    }
}
