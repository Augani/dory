// Preserve the public package/Xcode product identity while the daemon and runner share one
// implementation of the renderer bootstrap, receipt, command, and XPC wire protocol.
@_exported import DoryRendererWorkerWireContracts
