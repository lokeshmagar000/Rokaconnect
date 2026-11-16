package com.rokaconnect.portal

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.mutableStateListOf
import java.net.Inet4Address

/** Finds Macs running Rokaconnect on the local network (Bonjour / mDNS service "_rokaportal._tcp"). */
class MacFinder(context: Context) {
    private val ctx = context.applicationContext
    data class Mac(val name: String, val host: String, val port: Int)

    val macs = mutableStateListOf<Mac>()
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var lock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.DiscoveryListener? = null
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    fun start() {
        if (listener != null) return
        lock = wifi.createMulticastLock("rokaconnect").apply { setReferenceCounted(false); acquire() }
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { listener = null }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) { main.post { queue.addLast(info); resolveNext() } }
            override fun onServiceLost(info: NsdServiceInfo) { main.post { macs.removeAll { it.name == info.serviceName } } }
        }
        listener = l
        nsd.discoverServices(Portal.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        lock?.let { if (it.isHeld) it.release() }
        lock = null
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving) return
        val info = queue.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                main.post { resolving = false; resolveNext() }
            }
            override fun onServiceResolved(s: NsdServiceInfo) {
                val addr = if (Build.VERSION.SDK_INT >= 34) s.hostAddresses.firstOrNull { it is Inet4Address } ?: s.hostAddresses.firstOrNull()
                           else s.host
                main.post {
                    resolving = false
                    if (addr != null) {
                        val mac = Mac(s.serviceName, addr.hostAddress ?: "", s.port)
                        macs.removeAll { it.name == mac.name }
                        macs.add(mac)
                        Link.rememberHost(ctx, mac.host, mac.port)
                    }
                    resolveNext()
                }
            }
        })
    }
}
