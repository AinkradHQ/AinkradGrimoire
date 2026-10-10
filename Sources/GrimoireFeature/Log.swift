import AinkradAppKit
import os

/// The module's loggers. They all build on `AinkradLog`, so one Console filter
/// on the `com.ainkrad.app` subsystem covers the host and every plugin. The app
/// id is a literal because `GrimoireApp.id` is main-actor isolated and these are not;
/// `ainkrad new` rewrites it with the id.
enum Log {
    static let persistence = AinkradLog.logger(app: "grimoire", area: "persistence")
}
