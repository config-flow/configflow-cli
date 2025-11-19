// Re-export discovery module components for use as a shared module
pub const coordinator = @import("discovery/coordinator.zig");
pub const parser = @import("discovery/parsers/parser.zig");

// Re-export commonly used types
pub const Coordinator = coordinator.Coordinator;
pub const AggregatedEnvVar = coordinator.AggregatedEnvVar;
pub const DiscoveryResult = coordinator.DiscoveryResult;

pub const EnvVarUsage = parser.EnvVarUsage;
pub const Warning = parser.Warning;
pub const ConfigType = parser.ConfigType;
pub const Confidence = parser.Confidence;
pub const ParseResult = parser.ParseResult;
pub const Parser = parser.Parser;
