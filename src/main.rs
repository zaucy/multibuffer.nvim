use std::process::Command;
use std::fs;
use std::path::Path;
use std::env;

fn build_and_deploy() -> bool {
    println!("--- Building Multibuffer Plugin (Release) ---");
    let status = Command::new("cargo")
        .args(&["build", "--release"])
        .status();

    match status {
        Ok(s) if s.success() => {},
        _ => {
            eprintln!("Build failed!");
            return false;
        }
    }

    if !Path::new("lua").exists() {
        fs::create_dir("lua").expect("Failed to create lua directory");
    }

    let src = "target/release/multibuffer.dll";
    let dst = "lua/multibuffer.dll";

    if Path::new(src).exists() {
        println!("--- Deploying plugin to {} ---", dst);
        // Try to remove old one, ignore error if it's not there
        let _ = fs::remove_file(dst);
        if let Err(e) = fs::copy(src, dst) {
            eprintln!("Failed to copy DLL: {}. Is Neovim already running and using the file?", e);
            return false;
        }
    } else {
        eprintln!("Could not find built DLL at {}", src);
        return false;
    }
    true
}

fn main() {
    let args: Vec<String> = env::args().collect();
    
    if !build_and_deploy() {
        std::process::exit(1);
    }

    if args.len() > 1 && args[1] == "test" {
        println!("--- Running Automated Tests ---");
        let status = Command::new("nvim")
            .args(&[
                "--headless",
                "--noplugin",
                "-u", "NONE",
                "-c", "set rtp+=.",
                "-l", "test/automated.lua"
            ])
            .status()
            .expect("Failed to launch Neovim");
        
        if status.success() {
            println!("Tests passed!");
        } else {
            eprintln!("Tests failed!");
            std::process::exit(1);
        }
    } else {
        println!("--- Launching Neovim (Manual Test) ---");
        println!("Path to manual test: {}", Path::new("test/manual.lua").canonicalize().unwrap().display());
        
        // On Windows, using cmd /C can help with terminal inheritance
        let mut nvim = Command::new("cmd")
            .args(&[
                "/C",
                "nvim",
                "--noplugin",
                "-u", "NONE",
                "-c", "set rtp+=.",
                "-c", "luafile test/manual.lua"
            ])
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .spawn()
            .expect("Failed to launch Neovim");

        let status = nvim.wait().expect("Failed to wait for Neovim");
        println!("Neovim exited with status: {}", status);
    }
}
