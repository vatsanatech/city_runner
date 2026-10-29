package `in`.stage.cityrunner

import android.app.Activity
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

abstract class CityRunnerRuntime : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    abstract var onEvent: ((String, Map<String, Any>) -> Unit)?
    abstract val playing: Boolean
    abstract fun attachActivity(activity: Activity?)
    abstract fun launch(city: String, common: File, packs: List<File>, result: MethodChannel.Result)
    abstract fun back()
    abstract fun close()
    abstract fun hostClosed()
}
