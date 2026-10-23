package com.novabox.flutter

import android.app.Application
import com.mobile.js.App
import com.whl.quickjs.android.QuickJSLoader
import com.github.catvod.server.LocalServer

class NovaboxApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        App.shared = this
        QuickJSLoader.init(true)
        LocalServer.start()
    }
}
