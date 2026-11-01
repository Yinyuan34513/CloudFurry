// SPDX-License-Identifier: GPL-2.0-only
//! fpt — CloudFurry Linux 包管理器
//!
//! 完全基于 git 仓库的包下载方式：官方源在包管理器内定义
//! （https://github.com/Real-GNOS/furrypkgs.git），所有包操作
//! 通过 git clone/fetch 完成，不使用 HTTP 直链。
//!
//! 用法:
//!   fpt list              列出远程仓库中的所有包
//!   fpt update            git fetch 更新本地仓库缓存
//!   fpt install <pkg>     从 git 仓库安装包
//!   fpt upgrade           更新缓存并重装全部已安装包
//!   fpt search <kw>       按关键字搜索
//!   fpt installed         列出已安装包
//!   fpt repo              显示官方源地址
//!
//! 仓库布局（与 deep-repo 兼容）:
//!   packages/<name>/description   包描述
//!   packages/<name>/version       版本
//!   packages/<name>/files/...     安装载荷（相对 / 复制；无 files/ 时
//!                                 安装包目录内同名二进制到 /usr/bin）

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// 官方源（在包管理器内定义）
const OFFICIAL_REPO: &str = "https://github.com/Yinyuan34513/furrypkgs.git";
const CACHE_DIR: &str = "/var/cache/fpt";

/// 开发/测试时可用 FPT_CACHE 重定向缓存与状态目录
fn cache_dir() -> PathBuf {
    env::var("FPT_CACHE").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(CACHE_DIR))
}

fn state_dir() -> PathBuf {
    cache_dir().join("state")
}

fn repo_dir() -> String {
    cache_dir().join("repo").to_string_lossy().into_owned()
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let code = match args.first().map(|s| s.as_str()) {
        Some("list") => cmd_list(),
        Some("update") => cmd_update(),
        Some("install") => match args.get(1) {
            Some(p) => cmd_install(p),
            None => usage_err("install <pkg>"),
        },
        Some("upgrade") => cmd_upgrade(),
        Some("search") => match args.get(1) {
            Some(k) => cmd_search(k),
            None => usage_err("search <kw>"),
        },
        Some("installed") => cmd_installed(),
        Some("repo") => cmd_repo(),
        Some("help") | None => {
            print_help();
            0
        }
        Some(_) => {
            eprintln!("fpt: 未知命令: {}", args[0]);
            print_help();
            2
        }
    };
    std::process::exit(code);
}

fn print_help() {
    println!(
        "fpt {} — CloudFurry Linux 包管理器 (git 仓库下载)\n\
         官方源: {}\n\n\
         用法: fpt <list|update|install <pkg>|upgrade|search <kw>|installed|repo>",
        env!("CARGO_PKG_VERSION"),
        OFFICIAL_REPO
    );
}

fn usage_err(u: &str) -> i32 {
    eprintln!("fpt: 参数不足, 用法: fpt {u}");
    2
}

fn repo_url() -> String {
    env::var("FPT_REPO").unwrap_or_else(|_| OFFICIAL_REPO.to_string())
}

fn run_git(args: &[&str]) -> Result<(), String> {
    let st = Command::new("git")
        .args(args)
        .status()
        .map_err(|e| format!("git 未安装或无法执行: {e}"))?;
    if st.success() {
        Ok(())
    } else {
        Err(format!("git {:?} 失败 (exit {})", args, st.code().unwrap_or(-1)))
    }
}

/// 更新本地 git 仓库缓存（克隆或 fetch+reset）
fn sync_repo() -> Result<PathBuf, String> {
    let repo = PathBuf::from(repo_dir());
    fs::create_dir_all(cache_dir()).map_err(|e| e.to_string())?;
    if repo.join(".git").exists() {
        println!("fpt: git fetch 更新仓库缓存...");
        run_git(&["-C", &repo_dir(), "fetch", "--depth", "1", "origin"])?;
        run_git(&["-C", &repo_dir(), "reset", "--hard", "origin/HEAD"])
            .or_else(|_| run_git(&["-C", &repo_dir(), "reset", "--hard", "origin/master"]))?;
    } else {
        println!("fpt: git clone 官方源 {}...", repo_url());
        run_git(&["clone", "--depth", "1", &repo_url(), &repo_dir()])?;
    }
    Ok(repo)
}

fn pkg_dir(repo: &Path, name: &str) -> PathBuf {
    repo.join("packages").join(name)
}

fn read_meta(pkg: &Path, file: &str) -> Option<String> {
    fs::read_to_string(pkg.join(file)).ok().map(|s| s.trim().to_string())
}

fn pkgs_root(repo: &Path) -> PathBuf {
    repo.join("packages")
}

// ---------- 子命令 ----------

fn cmd_list() -> i32 {
    match sync_repo() {
        Ok(repo) => {
            let root = pkgs_root(&repo);
            let mut names: Vec<String> = fs::read_dir(&root)
                .map(|rd| {
                    rd.filter_map(|e| e.ok())
                        .filter(|e| e.path().is_dir())
                        .filter_map(|e| e.file_name().into_string().ok())
                        .collect()
                })
                .unwrap_or_default();
            names.sort();
            if names.is_empty() {
                println!("fpt: 仓库中没有包 (检查 {OFFICIAL_REPO})");
                return 1;
            }
            println!("{:<16} {:<10} 描述", "包名", "版本");
            for n in &names {
                let p = pkg_dir(&repo, n);
                let ver = read_meta(&p, "version").unwrap_or_default();
                let desc = read_meta(&p, "description").unwrap_or_default();
                println!("{:<16} {:<10} {}", n, ver, desc);
            }
            0
        }
        Err(e) => {
            eprintln!("fpt: {e}");
            1
        }
    }
}

fn cmd_update() -> i32 {
    match sync_repo() {
        Ok(_) => {
            println!("fpt: 仓库缓存已更新");
            0
        }
        Err(e) => {
            eprintln!("fpt: {e}");
            1
        }
    }
}

fn mark_installed(name: &str, version: &str) -> Result<(), String> {
    let dir = state_dir();
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    fs::write(dir.join(name), version).map_err(|e| e.to_string())
}

fn install_one(repo: &Path, name: &str) -> Result<(), String> {
    let p = pkg_dir(repo, name);
    if !p.is_dir() {
        return Err(format!("包 {name} 不在官方源中"));
    }
    let payload = p.join("files");
    let target_root = Path::new("/");
    if payload.is_dir() {
        // files/ 下的相对路径逐文件复制到 /
        let mut count = 0usize;
        copy_tree(&payload, target_root, &mut count)?;
        println!("fpt: 已安装 {name} ({} 个文件 → /)", count);
    } else if let Ok(entries) = fs::read_dir(&p) {
        // 无 files/ 时: 包目录内可执行文件 → /usr/bin
        let mut count = 0usize;
        for e in entries.filter_map(|e| e.ok()) {
            let f = e.path();
            if f.is_file() && is_executable(&f) {
                let dest = Path::new("/usr/bin").join(e.file_name());
                fs::copy(&f, &dest).map_err(|e| format!("复制 {}: {e}", f.display()))?;
                set_exec(&dest);
                count += 1;
            }
        }
        if count == 0 {
            return Err(format!("包 {name} 无安装载荷 (files/ 或可执行文件)"));
        }
        println!("fpt: 已安装 {name} ({count} 个二进制 → /usr/bin)");
    }
    let ver = read_meta(&p, "version").unwrap_or_else(|| "0".into());
    mark_installed(name, &ver)?;
    Ok(())
}

fn cmd_install(name: &str) -> i32 {
    match sync_repo().and_then(|repo| install_one(&repo, name).map(|_| repo)) {
        Ok(_) => 0,
        Err(e) => {
            eprintln!("fpt: 安装失败: {e}");
            1
        }
    }
}

fn cmd_upgrade() -> i32 {
    let repo = match sync_repo() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("fpt: {e}");
            return 1;
        }
    };
    let state = state_dir();
    let installed: Vec<String> = match fs::read_dir(&state) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .collect(),
        Err(_) => vec![],
    };
    if installed.is_empty() {
        println!("fpt: 没有已安装的包");
        return 0;
    }
    let mut fail = 0;
    for name in &installed {
        if let Err(e) = install_one(&repo, name) {
            eprintln!("fpt: {name}: {e}");
            fail += 1;
        }
    }
    if fail == 0 {
        println!("fpt: 全部已安装包已升级");
        0
    } else {
        1
    }
}

fn cmd_search(kw: &str) -> i32 {
    let repo = match sync_repo() {
        Ok(r) => r,
        Err(e) => {
            eprintln!("fpt: {e}");
            return 1;
        }
    };
    let root = pkgs_root(&repo);
    let mut found = 0;
    if let Ok(rd) = fs::read_dir(&root) {
        let mut names: Vec<String> = rd
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        names.sort();
        for n in names {
            let p = pkg_dir(&repo, &n);
            let desc = read_meta(&p, "description").unwrap_or_default();
            if n.contains(kw) || desc.to_lowercase().contains(&kw.to_lowercase()) {
                println!("{:<16} {:<10} {}", n, read_meta(&p, "version").unwrap_or_default(), desc);
                found += 1;
            }
        }
    }
    if found == 0 {
        println!("fpt: 无匹配 \"{kw}\" 的包");
        return 1;
    }
    0
}

fn cmd_installed() -> i32 {
    let state = state_dir();
    let mut names: Vec<(String, String)> = match fs::read_dir(&state) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .filter_map(|e| {
                let n = e.file_name().into_string().ok()?;
                let v = fs::read_to_string(e.path()).ok()?.trim().to_string();
                Some((n, v))
            })
            .collect(),
        Err(_) => vec![],
    };
    names.sort();
    for (n, v) in names {
        println!("{:<16} {}", n, v);
    }
    0
}

fn cmd_repo() -> i32 {
    println!("{}", repo_url());
    0
}

// ---------- 工具 ----------

fn is_executable(p: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(p).map(|m| m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        p.is_file()
    }
}

fn set_exec(p: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(m) = fs::metadata(p) {
            let mut perm = m.permissions();
            perm.set_mode(0o755);
            let _ = fs::set_permissions(p, perm);
        }
    }
}

fn copy_tree(src: &Path, dst: &Path, count: &mut usize) -> Result<(), String> {
    for e in fs::read_dir(src).map_err(|e| e.to_string())? {
        let e = e.map_err(|e| e.to_string())?;
        let from = e.path();
        let to = dst.join(e.file_name());
        if from.is_dir() {
            fs::create_dir_all(&to).map_err(|e| e.to_string())?;
            copy_tree(&from, &to, count)?;
        } else if from.is_file() {
            if let Some(parent) = to.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            fs::copy(&from, &to).map_err(|e| format!("复制 {}: {e}", from.display()))?;
            set_exec(&to);
            *count += 1;
        }
    }
    Ok(())
}
