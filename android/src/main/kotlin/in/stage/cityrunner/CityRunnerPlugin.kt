package `in`.stage.cityrunner

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.google.android.play.core.splitcompat.SplitCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class CityRunnerPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var binding: ActivityPluginBinding? = null
    private var runtime: CityRunnerRuntime? = null
    private lateinit var installer: EngineInstall

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "in.stage.cityrunner")
        channel.setMethodCallHandler(this)
        installer = EngineInstall(context) { payload ->
            channel.invokeMethod("engineProgress", payload)
        }
        binding.platformViewRegistry.registerViewFactory("in.stage.cityrunner/view",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?) =
                    loadRuntime().create(context, viewId, args)
            })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val root = File(context.filesDir, "cityrunner").apply { mkdirs() }.canonicalFile
        when (call.method) {
            "cacheRoot" -> result.success(root.path)
            "engineInstalled" -> result.success(installer.installed())
            "installEngine" -> installer.install(result)
            "cancelEngine" -> {
                installer.cancel()
                result.success(null)
            }
            "verify" -> worker.execute {
                val verified = runCatching {
                    val file = File(call.argument<String>("path")!!).canonicalFile
                    require(file.parentFile == root)
                    val digest = MessageDigest.getInstance("SHA-256")
                    file.inputStream().use { input ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            digest.update(buffer, 0, count)
                        }
                    }
                    val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
                    file.length() == call.argument<Number>("bytes")!!.toLong() &&
                        actual == call.argument<String>("sha256")
                }.getOrDefault(false)
                main.post { result.success(verified) }
            }
            "launch" -> {
                val activity = binding?.activity
                if (activity == null || runtime?.playing == true || !installer.installed()) {
                    result.error("host_unavailable", "The game host is not available", null)
                    return
                }
                runCatching {
                    val common = File(call.argument<String>("common")!!).canonicalFile
                    val packs = call.argument<List<String>>("packs")!!.map { File(it).canonicalFile }
                    require(packs.isNotEmpty())
                    require((packs + common).all { it.parentFile == root && it.isFile && it.extension == "pck" })
                    val city = call.argument<String>("city")!!
                    require(city.matches(Regex("[a-z-]+")))
                    val engine = loadRuntime()
                    engine.launch(city, common, packs, result)
                }.onFailure {
                    result.error("launch_failed", "City Runner could not start", null)
                }
            }
            "close" -> {
                runtime?.close()
                result.success(null)
            }
            "back" -> {
                runtime?.back()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun loadRuntime(): CityRunnerRuntime = runtime ?: run {
        check(installer.installed())
        val activity = requireNotNull(binding?.activity)
        SplitCompat.install(context)
        SplitCompat.installActivity(activity)
        (Class.forName("in.stage.cityrunner.GodotRunnerRuntime", true, context.classLoader)
            .getDeclaredConstructor().newInstance() as CityRunnerRuntime).also {
            it.attachActivity(activity)
            it.onEvent = { name, payload ->
                main.post { channel.invokeMethod("gameEvent", payload + ("name" to name)) }
            }
            runtime = it
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
        installer.attach(binding.activity)
        if (runtime != null) SplitCompat.installActivity(binding.activity)
        runtime?.attachActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeActivityResultListener(this)
        installer.attach(null)
        runtime?.attachActivity(null)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        installer.cancel()
        runtime?.hostClosed()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runtime?.onEvent = null
        channel.setMethodCallHandler(null)
        installer.cancel()
        runtime?.hostClosed()
        worker.shutdown()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) =
        installer.onActivityResult(requestCode, resultCode)
}
