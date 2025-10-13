import PusherSwift
import Foundation

@objc(PusherWebsocketReactNative)
@objcMembers class PusherWebsocketReactNative: RCTEventEmitter, PusherDelegate, Authorizer {
    private static var shared: PusherWebsocketReactNative!
    private static var pusher: Pusher!

    private var authorizerCompletionHandlerTimeout = 10 // seconds
    private var channelsDataMap = [String: String]()

    private let subscriptionErrorType = "SubscriptionError"
    private let authErrorType = "AuthError"
    private let pusherEventPrefix = "PusherReactNative"
    
    private let syncQueue = DispatchQueue(label: "com.salesmessage.arcadia.PusherWebSocketSyncQueue")

    override init() {
        super.init()

        PusherWebsocketReactNative.shared = self
    }

    override func supportedEvents() -> [String]! {
        return ["\(pusherEventPrefix):onConnectionStateChange",
                "\(pusherEventPrefix):onSubscriptionError",
                "\(pusherEventPrefix):onSubscriptionCount",
                "\(pusherEventPrefix):onAuthorizer",
                "\(pusherEventPrefix):onError",
                "\(pusherEventPrefix):onDecryptionFailure",
                "\(pusherEventPrefix):onEvent",
                "\(pusherEventPrefix):onMemberAdded",
                "\(pusherEventPrefix):onMemberRemoved"]
    }

    private func callback(name:String, body:Any) -> Void {
        let pusherEventname = "\(pusherEventPrefix):\(name)"
        PusherWebsocketReactNative.shared.sendEvent(withName:pusherEventname, body:body)
    }
  
    private func sendSubscriptionErrorMessage(_ message: String, channelName: String) {
      let code = ""
      let type = subscriptionErrorType

      PusherWebsocketReactNative.shared.callback(name:"onSubscriptionError", body:[
          "message": message,
          "type": type,
          "code": code,
          "channelName": channelName
      ])
    }

    func initialize(_ args:[String: Any], resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock) {
        if PusherWebsocketReactNative.pusher != nil {
            PusherWebsocketReactNative.pusher.unsubscribeAll()
            PusherWebsocketReactNative.pusher.disconnect()
            channelsDataMap.removeAll()
        }
        var authMethod:AuthMethod = .noMethod
        if args["authEndpoint"] is String {
            authMethod = .endpoint(authEndpoint: args["authEndpoint"] as! String)
        } else if args["authorizer"] is Bool {
            authMethod = .authorizer(authorizer: PusherWebsocketReactNative.shared)
        }
        var host:PusherHost = .defaultHost
        if args["host"] is String {
            host = .host(args["host"] as! String)
        } else if args["cluster"] != nil {
            host = .cluster(args["cluster"] as! String)
        }
        var useTLS:Bool = true
        if args["useTLS"] is Bool {
            useTLS = args["useTLS"] as! Bool
        }
        var port:Int
        if useTLS {
            port = 443
            if args["wssPort"] is Int {
                port = args["wssPort"] as! Int
            }
        } else {
            port = 80
            if args["wsPort"] is Int {
                port = args["wsPort"] as! Int
            }
        }
        var activityTimeout:TimeInterval? = nil
        if args["activityTimeout"] is TimeInterval {
            activityTimeout = args["activityTimeout"] as! Double / 1000.0
        }
        var path:String? = nil
        if args["path"] is String {
            path = (args["path"] as! String)
        }
        let options = PusherClientOptions(
            authMethod: authMethod,
            host: host,
            port: port,
            path: path,
            useTLS: useTLS,
            activityTimeout: activityTimeout
        )
        PusherWebsocketReactNative.pusher = Pusher(key: args["apiKey"] as! String, options: options)
        if args["maxReconnectionAttempts"] is Int {
            PusherWebsocketReactNative.pusher.connection.reconnectAttemptsMax = (args["maxReconnectionAttempts"] as! Int)
        }
        if args["maxReconnectGapInSeconds"] is TimeInterval {
            PusherWebsocketReactNative.pusher.connection.maxReconnectGapInSeconds = (args["maxReconnectGapInSeconds"] as! TimeInterval)
        }
        if args["pongTimeout"] is Int {
            PusherWebsocketReactNative.pusher.connection.pongResponseTimeoutInterval = args["pongTimeout"] as! TimeInterval / 1000.0
        }

        if let authorizerTimeoutInSeconds = args["authorizerTimeoutInSeconds"] as? Int {
            PusherWebsocketReactNative.shared.authorizerCompletionHandlerTimeout = authorizerTimeoutInSeconds
        }

        PusherWebsocketReactNative.pusher.connection.delegate = PusherWebsocketReactNative.shared
        PusherWebsocketReactNative.pusher.bind(eventCallback: onEvent)
        resolve(nil)
    }

    override static func requiresMainQueueSetup() -> Bool {
        return false
    }

    public func fetchAuthValue(socketID: String, channelName: String, completionHandler: @escaping (PusherAuth?) -> Void) {
        if channelsDataMap[channelName] == nil {
            self.sendSubscriptionErrorMessage("channelData not found", channelName: channelName)
            return
        }

        let authData = channelsDataMap.removeValue(forKey: channelName)

        if let jsonData = authData?.data(using: .utf8) {
            if let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let auth: String?
                let channelData: String?
                let sharedSecret: String?

                if let authValue = json["auth"] as? String {
                    auth = authValue
                } else {
                    auth = nil
                }

                if let channelDataValue = json["channel_data"] as? String {
                    channelData = channelDataValue
                } else {
                    channelData = nil
                }

                if let sharedSecretValue = json["shared_secret"] as? String {
                    sharedSecret = sharedSecretValue
                } else {
                    sharedSecret = nil
                }

                if auth != nil && !auth!.isEmpty {
                    completionHandler(PusherAuth(auth: auth!, channelData: channelData, sharedSecret: sharedSecret))
                } else {
                    completionHandler(PusherAuth(auth: "<missing_auth_param>:error", channelData: channelData, sharedSecret: sharedSecret))
                    self.sendSubscriptionErrorMessage("Missing auth parameter", channelName: channelName)
                }
            } else {
                print("Failed to parse JSON")
                self.sendSubscriptionErrorMessage("Failed to parse JSON", channelName: channelName)
            }
        } else {
            print("Failed to convert string to data")
          self.sendSubscriptionErrorMessage("Failed to convert string to data", channelName: channelName)
        }
    }

    public func onAuthorizer(_ channelName: String, socketID: String, data:[String:String], resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock) {
          print("DEBUG:", "onAuthorizer called")
    }

    public func changedConnectionState(from old: ConnectionState, to new: ConnectionState) {
        PusherWebsocketReactNative.shared.callback(name:"onConnectionStateChange", body:[
            "previousState": old.stringValue(),
            "currentState": new.stringValue()
        ])
    }

    public func debugLog(message: String) {
        //print("DEBUG:", message)
    }

    public func subscribedToChannel(name: String) {
        // Handled by global handler
    }

    public func failedToSubscribeToChannel(name: String, response: URLResponse?, data: String?, error: NSError?) {
        var code = ""
        var type = subscriptionErrorType
        if let httpResponse = response as? HTTPURLResponse {
            code = String(httpResponse.statusCode)
            type = authErrorType
        }

        PusherWebsocketReactNative.shared.callback(name:"onSubscriptionError", body:[
            "message": (error != nil) ? error!.localizedDescription : ((data != nil) ? data! : error.debugDescription),
            "type": type,
            "code": code,
            "channelName": name
        ])
    }

    public func receivedError(error: PusherError) {
        PusherWebsocketReactNative.shared.callback(
            name:"onError", body:[
                "message": error.message,
                "code": error.code ?? -1,
                "error": error.debugDescription
            ]
        )
    }

    public func failedToDecryptEvent(eventName: String, channelName: String, data: String?) {
        PusherWebsocketReactNative.shared.callback(
            name:"onDecryptionFailure", body:[
                "eventName": eventName,
                "reason": data
            ]
        )
    }

    public func connect(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock) {
        PusherWebsocketReactNative.pusher.connect()
        resolve(nil)
    }

    public func disconnect(_ resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock) {
        PusherWebsocketReactNative.pusher.disconnect()
        channelsDataMap.removeAll()
        resolve(nil)
    }

    public func getSocketId(_ resolve:RCTPromiseResolveBlock, reject:RCTPromiseRejectBlock) {
        let socketId = PusherWebsocketReactNative.pusher.connection.socketId
        resolve(socketId)
    }

    func onEvent(event:PusherEvent) {
        var userId:String? = nil
        var mappedEventName:String? = nil
        if event.eventName == "pusher:subscription_succeeded" {
            if let channel = PusherWebsocketReactNative.pusher.connection.channels.findPresence(name: event.channelName!) {
                userId = channel.myId
            }
            mappedEventName = "pusher_internal:subscription_succeeded"
        }
        PusherWebsocketReactNative.shared.callback(
            name:"onEvent",body:[
                "channelName": event.channelName,
                "eventName": mappedEventName ?? event.eventName,
                "userId": event.userId ?? userId,
                "data": event.data,
                "raw": event.property(withKey: "data"),
            ]
        )
    }

    func subscribe(_ channelName:String, channelData: String, resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock) {
        self.channelsDataMap[channelName] = channelData
        if channelName.hasPrefix("presence-") {
            let onMemberAdded:(PusherPresenceChannelMember) -> () = { user in
                PusherWebsocketReactNative.shared.callback(name:"onMemberAdded", body: [
                    "channelName": channelName,
                    "user": ["userId": user.userId, "userInfo": user.userInfo ]
                ])
            }
            let onMemberRemoved:(PusherPresenceChannelMember) -> () = { user in
                PusherWebsocketReactNative.shared.callback(name:"onMemberRemoved", body: [
                    "channelName": channelName,
                    "user": ["userId": user.userId, "userInfo": user.userInfo ]
                ])
            }
            PusherWebsocketReactNative.pusher.subscribeToPresenceChannel(
                channelName: channelName,
                onMemberAdded: onMemberAdded,
                onMemberRemoved: onMemberRemoved
            )
        } else {
            let onSubscriptionCount:(Int) -> () = { subscriptionCount in
                PusherWebsocketReactNative.shared.callback(
                    name:"onEvent",body:[
                        "channelName": channelName,
                        "eventName": "pusher_internal:subscription_count",
                        "userId": nil,
                        "data": [
                            "subscription_count": subscriptionCount
                        ]
                    ]
                )
            }
            PusherWebsocketReactNative.pusher.subscribe(channelName: channelName,
                                                        onSubscriptionCountChanged: onSubscriptionCount)
        }
        resolve(nil)
    }

    func unsubscribe(_ channelName:String, resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock) {
        PusherWebsocketReactNative.pusher.unsubscribe(channelName)
        resolve(nil)
    }

    func trigger(_ channelName:String, eventName:String, data:Any, resolve:RCTPromiseResolveBlock,reject:RCTPromiseRejectBlock) {
        if let channel = PusherWebsocketReactNative.pusher.connection.channels.find(name: channelName) {
            channel.trigger(eventName: eventName, data: data)
        }
        resolve(nil)
    }
}
