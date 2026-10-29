package `in`.stage.cityrunner

import android.app.Activity
import android.app.Application
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import org.godotengine.godot.Godot
import org.godotengine.godot.GodotHost
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference

class GodotRunnerRuntime : CityRunnerRuntime(), GodotHost,
    Application.ActivityLifecycleCallbacks {
    override var onEvent: ((String, Map<String, Any>) -> Unit)? = null
    private var host = WeakReference<Activity>(null)
    private var engine: Godot? = null
    private var bridge: CityRunnerHost? = null
    private var pending: MethodChannel.Result? = null
    private var launchData = "{}"
    private var layout: View? = null
    private var audio: AudioManager? = null
    private var focus: AudioFocusRequest? = null
    private var application: Application? = null
    private var previousWindowFlags = 0
    private var previousSystemUi = 0
    override val playing: Boolean get() = pending != null

    override fun getActivity(): Activity? = host.get()
    override fun getGodot(): Godot? = engine
    override fun getCommandLine() = listOf("--rendering-method", "gl_compatibility")

    override fun attachActivity(activity: Activity?) {
        host = WeakReference(activity)
        if (activity != null && application == null) {
            application = activity.application
            application!!.registerActivityLifecycleCallbacks(this)
        }
    }

    override fun launch(city: String, common: File, packs: List<File>, result: MethodChannel.Result) {
        val activity = host.get() ?: error("The game host is not available")
        previousWindowFlags = activity.window.attributes.flags
        previousSystemUi = activity.window.decorView.systemUiVisibility
        launchData = JSONObject().put("city", city).put("common", common.path)
            .put("packs", JSONArray(packs.map { it.path })).toString()
        pending = result
        if (layout != null) {
            engine?.enableImmersiveMode(true)
            resume()
            bridge?.open()
        }
    }

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val activity = host.get() ?: error("The game host is not available")
        val godot = engine ?: Godot.getInstance(context.applicationContext).also { engine = it }
        val reopening = bridge != null
        if (!reopening) {
            bridge = CityRunnerHost(godot, this)
            check(godot.initEngine(this, commandLine, setOf(bridge!!)))
        }
        val view = requireNotNull(godot.onInitRenderView(this, FrameLayout(context.applicationContext)))
        (view.parent as? ViewGroup)?.removeView(view)
        layout = view
        audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).build())
            .setOnAudioFocusChangeListener { change ->
                if (playing && change < 0) godot.onPause(this)
                if (playing && change == AudioManager.AUDIOFOCUS_GAIN) godot.onResume(this)
            }.build()
        godot.enableImmersiveMode(true)
        resume()
        if (reopening && playing) bridge!!.open()
        return object : PlatformView {
            override fun getView() = view
            override fun dispose() {
                pause()
                (view.parent as? ViewGroup)?.removeView(view)
                layout = null
                // Keep the single Godot engine; its destruction can terminate the host process.
            }
        }
    }

    fun event(name: String, payload: String) {
        if (!playing || name !in setOf("native_ready", "run_started", "run_paused", "run_resumed", "run_finished")) return
        val data = JSONObject(payload)
        val properties = data.keys().asSequence().associateWith { data.get(it) }
        onEvent?.invoke(name, properties)
    }

    fun data() = launchData
    override fun back() { if (playing) engine?.onBackPressed() }
    override fun close() { if (playing) bridge?.close() }

    fun finished(error: String? = null) {
        val activity = host.get() ?: return
        activity.runOnUiThread {
            pause()
            engine?.enableImmersiveMode(false)
            activity.window.setFlags(previousWindowFlags, -1)
            activity.window.decorView.systemUiVisibility = previousSystemUi
            val result = pending
            pending = null
            if (error == null) result?.success(null)
            else result?.error("game_closed", error, null)
        }
    }

    private fun pause() {
        focus?.let { audio?.abandonAudioFocusRequest(it) }
        engine?.onPause(this)
        engine?.onStop(this)
    }

    private fun resume() {
        val request = focus ?: return
        if (audio?.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            engine?.onStart(this)
            engine?.onResume(this)
        } else {
            finished("City Runner could not acquire audio focus")
        }
    }

    override fun hostClosed() {
        pause()
        application?.unregisterActivityLifecycleCallbacks(this)
        application = null
        pending?.error("host_closed", "The game host closed", null)
        pending = null
    }

    override fun onGodotForceQuit(instance: Godot) =
        finished("The game engine stopped unexpectedly")

    override fun onActivityPaused(activity: Activity) {
        if (activity === host.get() && playing) pause()
    }
    override fun onActivityResumed(activity: Activity) {
        if (activity === host.get() && playing && layout != null) {
            resume()
        }
    }
    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) {}
}

internal class CityRunnerHost(godot: Godot, private val runtime: GodotRunnerRuntime) : GodotPlugin(godot) {
    override fun getPluginName() = "CityRunnerHost"
    override fun getPluginSignals() = setOf(SignalInfo("open_requested"), SignalInfo("close_requested"))
    @UsedByGodot fun launchData() = runtime.data()
    @UsedByGodot fun reportEvent(name: String, payload: String) = runtime.event(name, payload)
    @UsedByGodot fun closeGame() = runtime.finished()
    @UsedByGodot fun failGame(message: String) = runtime.finished(message)
    fun open() = emitSignal("open_requested")
    fun close() = emitSignal("close_requested")
}
