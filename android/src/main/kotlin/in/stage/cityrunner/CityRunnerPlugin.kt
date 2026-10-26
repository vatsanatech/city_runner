package `in`.stage.cityrunner

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class CityRunnerPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var binding: ActivityPluginBinding? = null
    private val runtime = CityRunnerRuntime()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "in.stage.cityrunner")
        channel.setMethodCallHandler(this)
        binding.platformViewRegistry.registerViewFactory("in.stage.cityrunner/view", runtime)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val root = File(context.filesDir, "cityrunner").apply { mkdirs() }.canonicalFile
        when (call.method) {
            "cacheRoot" -> result.success(root.path)
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
                if (activity == null || runtime.playing) {
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
                    runtime.launch(city, common, packs, result)
                }.onFailure {
                    result.error("launch_failed", "City Runner could not start", null)
                }
            }
            "back" -> {
                runtime.back()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        runtime.attachActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        runtime.attachActivity(null)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        runtime.hostClosed()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        runtime.hostClosed()
        worker.shutdown()
    }
}
