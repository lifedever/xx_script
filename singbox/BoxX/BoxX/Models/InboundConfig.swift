// BoxX/Models/InboundConfig.swift
// Inbounds are polymorphic by type but we don't need to edit them programmatically.
// Using JSONValue preserves everything perfectly through round-trips.
import Foundation

typealias Inbound = JSONValue
