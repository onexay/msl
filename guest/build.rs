// SPDX-License-Identifier: Apache-2.0
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=../proto/msl/v1/msl.proto");
    tonic_prost_build::configure()
        .build_client(false)
        .compile_protos(&["../proto/msl/v1/msl.proto"], &["../proto"])?;
    Ok(())
}
