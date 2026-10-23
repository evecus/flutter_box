package com.mobile.js

import com.whl.quickjs.wrapper.JSCallFunction
import com.whl.quickjs.wrapper.JSFunction
import com.whl.quickjs.wrapper.JSObject
import java.util.concurrent.CompletableFuture

object Async {

    fun run(object1: JSObject?, name: String, args: Array<out Any?>): CompletableFuture<Any?> {
        val future = CompletableFuture<Any?>()
        try {
            if (object1 == null) {
                future.complete(null)
                return future
            }
            val function = object1.getJSFunction(name)
            if (function == null) {
                future.complete(null)
                return future
            }
            val result = function.call(*args)
            if (result is JSObject) {
                then(result, future)
            } else {
                future.complete(result)
            }
        } catch (t: Throwable) {
            future.completeExceptionally(t)
        }
        return future
    }

    private fun then(result: JSObject, future: CompletableFuture<Any?>) {
        val thenFn = result.getJSFunction("then")
        if (thenFn != null) {
            thenFn.call(object : JSCallFunction {
                override fun call(vararg args: Any?): Any? {
                    future.complete(if (args.isNotEmpty()) args[0] else null)
                    return null
                }
            })
        } else {
            future.complete(result)
        }
    }
}

object FunCall {

    fun call(jsObject: JSObject?, name: String, args: Array<out Any?>): CompletableFuture<Any?> {
        return Async.run(jsObject, name, args)
    }
}
