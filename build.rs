fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    println!("cargo:rerun-if-changed=src/env/keychain.m");
    cc::Build::new()
        .file("src/env/keychain.m")
        .flag("-fobjc-arc")
        .compile("vaultty-keychain");

    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Security");
}
