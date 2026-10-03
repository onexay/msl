// SPDX-License-Identifier: Apache-2.0
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=../core/proto/msl/v1/msl.proto");
    tonic_prost_build::configure()
        .build_client(false)
        .compile_protos(&["../core/proto/msl/v1/msl.proto"], &["../core/proto"])?;
    Ok(())
}
