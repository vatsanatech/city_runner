# The optional runtime is instantiated only after Play installs its split.
-keep class in.stage.cityrunner.GodotRunnerRuntime { public <init>(); }
-keep class in.stage.cityrunner.CityRunnerRuntime { *; }
