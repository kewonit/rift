import NetworkExtension

let runtime = RuntimeEnvironment.policy
let listener = FilterServiceListener(runtime: runtime)
listener.resume()
NEProvider.startSystemExtensionMode()
dispatchMain()
