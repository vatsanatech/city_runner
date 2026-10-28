package `in`.stage.cityrunner

import android.app.Activity
import android.content.Context
import com.google.android.play.core.splitcompat.SplitCompat
import com.google.android.play.core.splitinstall.SplitInstallManagerFactory
import com.google.android.play.core.splitinstall.SplitInstallRequest
import com.google.android.play.core.splitinstall.SplitInstallSessionState
import com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
import com.google.android.play.core.splitinstall.model.SplitInstallSessionStatus
import com.google.android.play.core.splitinstall.model.SplitInstallErrorCode
import io.flutter.plugin.common.MethodChannel

internal class EngineInstall(
    private val context: Context,
    private val progress: (Map<String, Any>) -> Unit
) {
    private val manager by lazy { SplitInstallManagerFactory.create(context) }
    private var pending: MethodChannel.Result? = null
    private var activity: Activity? = null
    private var session = 0
    private var attempt = 0
    private var receivedUpdate = false
    private var confirming = false
    private var confirmation: SplitInstallSessionState? = null
    private val listener = SplitInstallStateUpdatedListener { state ->
        if (pending != null && state.status() == SplitInstallSessionStatus.FAILED &&
            state.errorCode() == SplitInstallErrorCode.SERVICE_DIED) {
            finish("engine_unavailable", "Google Play disconnected. Please retry the engine download.")
        } else if (pending != null && state.sessionId() == session && MODULE in state.moduleNames()) {
            receivedUpdate = true
            update(state)
        }
    }

    fun installed(): Boolean {
        SplitCompat.install(context)
        return MODULE in manager.installedModules
    }

    fun attach(activity: Activity?) {
        this.activity = activity
        if (activity != null && confirmation != null) confirm()
    }

    fun install(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("engine_busy", "The game engine is already downloading", null)
            return
        }
        if (installed()) {
            result.success(null)
            return
        }
        SplitCompat.install(context)
        pending = result
        receivedUpdate = false
        val current = ++attempt
        manager.registerListener(listener)
        manager.startInstall(SplitInstallRequest.newBuilder().addModule(MODULE).build())
            .addOnSuccessListener { id ->
                if (current != attempt || pending == null) manager.cancelInstall(id)
                else if (id == 0 && installed()) finish()
                else {
                    session = id
                    manager.getSessionState(id).addOnSuccessListener { state ->
                        if (current == attempt && pending != null && !receivedUpdate) update(state)
                    }.addOnFailureListener {
                        if (current == attempt) finish("engine_unavailable",
                            "The game engine installation could not be checked. Please retry.")
                    }
                }
            }
            .addOnFailureListener {
                if (current == attempt) finish("engine_unavailable",
                    "The game engine could not download from Google Play. Check your connection and retry. " +
                        "Install STAGE from Google Play to use on-demand games.")
            }
    }

    private fun update(state: SplitInstallSessionState) {
        session = state.sessionId()
        progress(mapOf("received" to state.bytesDownloaded(), "total" to state.totalBytesToDownload(),
            "status" to state.status()))
        when (state.status()) {
            SplitInstallSessionStatus.REQUIRES_USER_CONFIRMATION -> {
                confirmation = state
                confirm()
            }
            SplitInstallSessionStatus.INSTALLED -> {
                SplitCompat.install(context)
                activity?.let { SplitCompat.installActivity(it) }
                finish()
            }
            SplitInstallSessionStatus.FAILED -> finish("engine_unavailable",
                "The game engine download failed (${state.errorCode()}). Check Google Play and retry.")
            SplitInstallSessionStatus.CANCELED -> finish("cancelled", "Download cancelled")
            else -> Unit
        }
    }

    private fun confirm() {
        if (confirming) return
        val host = activity ?: return
        val state = confirmation ?: return
        confirmation = null
        confirming = true
        runCatching {
            check(manager.startConfirmationDialogForResult(state, host, CONFIRMATION))
        }
            .onFailure { cancel() }
    }

    fun onActivityResult(request: Int, result: Int): Boolean {
        if (request != CONFIRMATION || !confirming) return false
        confirming = false
        if (result != Activity.RESULT_OK) cancel()
        return true
    }

    fun cancel() {
        if (pending == null) return
        if (session != 0) manager.cancelInstall(session)
        finish("cancelled", "Download cancelled")
    }

    private fun finish(code: String? = null, message: String? = null) {
        val result = pending ?: return
        pending = null
        attempt++
        session = 0
        confirmation = null
        confirming = false
        manager.unregisterListener(listener)
        if (code == null) result.success(null) else result.error(code, message, null)
    }

    companion object {
        const val MODULE = "city_runner_engine"
        private const val CONFIRMATION = 7391
    }
}
