// SPDX-License-Identifier: MIT
// Copyright (c) 2026 wangzhuo

import Foundation

/// Why an API request could not be pointed at a concrete engine/model.
enum GatewayModelPreparationError: Error, Equatable {
    case modelNotFound(String)
    case badRequest(String)
    case unavailable(String)
    case failed(String)

    var message: String {
        switch self {
        case .modelNotFound(let message),
            .badRequest(let message),
            .unavailable(let message),
            .failed(let message):
            return message
        }
    }
}
