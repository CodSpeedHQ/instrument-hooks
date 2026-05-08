//! Serializes the shared `Command` enum to test whether Zig deserializes it correctly.
//!
//! # Run
//!
//! ```bash
//! cargo run > serialized.zig
//! ```

// Import from runner-shared to ensure we use the same types
use runner_shared::fifo::{Command, IntegrationMode, MarkerType};

fn dump(name: &str, result: &Vec<u8>) {
    print!("pub const {}: []const u8 = &.{{ ", name);
    for byte in result.iter() {
        print!("0x{:X}, ", byte);
    }
    println!(" }};");
}

fn example<T: serde::Serialize>(name: &str, value: &T) {
    let result = bincode::serialize(&value).unwrap();
    dump(name, &result);
}

fn main() {
    println!("// This file is generated using 'cargo run > serialized.zig'");
    println!("// zig fmt: off");
    println!("");

    example(
        "cmd_cur_bench",
        &Command::CurrentBenchmark {
            pid: 12345,
            uri: "http://example.com/benchmark".to_string(),
        },
    );
    example("cmd_start_bench", &Command::StartProfiler);
    example("cmd_stop_bench", &Command::StopProfiler);
    example("cmd_ack", &Command::Ack);
    example("cmd_ping_perf", &Command::PingProfiler);
    example(
        "cmd_set_integration",
        &Command::SetIntegration {
            name: "test-integration".to_string(),
            version: "1.0.0".to_string(),
        },
    );
    example("cmd_err", &Command::Err);
    example(
        "cmd_add_marker_sample_start",
        &Command::AddMarker {
            pid: 12345,
            marker: MarkerType::SampleStart(1000),
        },
    );
    example(
        "cmd_add_marker_sample_end",
        &Command::AddMarker {
            pid: 12345,
            marker: MarkerType::SampleEnd(2000),
        },
    );
    example(
        "cmd_add_marker_benchmark_start",
        &Command::AddMarker {
            pid: 12345,
            marker: MarkerType::RoundStart(3000),
        },
    );
    example(
        "cmd_add_marker_benchmark_end",
        &Command::AddMarker {
            pid: 12345,
            marker: MarkerType::RoundEnd(4000),
        },
    );
    example("cmd_set_version", &Command::SetVersion(1));
    example("cmd_get_runner_mode", &Command::GetIntegrationMode);
    example(
        "cmd_runner_mode_perf",
        &Command::IntegrationModeResponse(IntegrationMode::Walltime),
    );
    example(
        "cmd_runner_mode_simulation",
        &Command::IntegrationModeResponse(IntegrationMode::Simulation),
    );
    example(
        "cmd_runner_mode_analysis",
        &Command::IntegrationModeResponse(IntegrationMode::Analysis),
    );
}
