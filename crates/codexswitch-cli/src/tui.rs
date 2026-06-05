use crate::account_store::active_account as active_imported_account;
use crate::account_store::{active_account, load_accounts};
use crate::auth::write_auth_file;
use crate::hermes;
use crate::import::import_bundle;
use crate::readiness;
use crate::{doctor, fix_codex, install_patched_codex, poll, restart_codex, status, swap};
use anyhow::{Context, Result};
use std::io::{self, Write};
use std::path::PathBuf;

pub fn run(store_path: &PathBuf, auth_path: &PathBuf) -> Result<()> {
    loop {
        print_readiness(store_path, auth_path)?;
        println!();
        println!("CodexSwitch Linux");
        println!("1) Status");
        println!("2) Doctor");
        println!("3) Poll all accounts");
        println!("4) Swap account");
        println!("5) Update token bundle");
        println!("6) Restart Codex CLI");
        println!("7) Fix broken Codex CLI");
        println!("8) Install/update patched Codex");
        println!("9) Hermes status");
        println!("10) Apply active token to Hermes");
        println!("11) Quit");
        print!("Select: ");
        io::stdout().flush().ok();

        let choice = read_line()?;
        match choice.trim() {
            "1" => status(store_path)?,
            "2" => doctor(store_path, auth_path, false)?,
            "3" => poll(store_path, None)?,
            "4" => choose_swap(store_path, auth_path)?,
            "5" => update_bundle(store_path, auth_path)?,
            "6" => restart_codex_interactive()?,
            "7" => fix_codex_interactive()?,
            "8" => install_patched_codex_interactive()?,
            "9" => hermes::status(false, false)?,
            "10" => apply_hermes_interactive(store_path)?,
            "11" | "q" | "quit" => return Ok(()),
            _ => println!("Unknown choice"),
        }
    }
}

fn apply_hermes_interactive(store_path: &PathBuf) -> Result<()> {
    print!("Restart Hermes gateway after applying token? [y/N]: ");
    io::stdout().flush().ok();
    let restart_gateway = matches!(read_line()?.trim(), "y" | "Y" | "yes" | "YES");
    let accounts = load_accounts(store_path)?;
    hermes::apply_active(&accounts, restart_gateway, false)
}

fn install_patched_codex_interactive() -> Result<()> {
    print!("Codex source path [~/.local/share/codexswitch/codex-source]: ");
    io::stdout().flush().ok();
    let source = read_line()?;
    let source = if source.trim().is_empty() {
        shellexpand_tilde("~/.local/share/codexswitch/codex-source")
    } else {
        shellexpand_tilde(source.trim())
    };
    print!("Replace /usr/bin/codex and npm vendor binary now? [y/N]: ");
    io::stdout().flush().ok();
    let yes = matches!(read_line()?.trim(), "y" | "Y" | "yes" | "YES");
    install_patched_codex(source, yes, yes, yes)
}

fn fix_codex_interactive() -> Result<()> {
    print!("Reinstall known-good @openai/codex if broken? [y/N]: ");
    io::stdout().flush().ok();
    let yes = matches!(read_line()?.trim(), "y" | "Y" | "yes" | "YES");
    fix_codex(yes, "0.125.0")
}

fn restart_codex_interactive() -> Result<()> {
    print!("Include Codex app-server too? [y/N]: ");
    io::stdout().flush().ok();
    let include_app_server = matches!(read_line()?.trim(), "y" | "Y" | "yes" | "YES");
    print!("Terminate matching Codex process(es) now? [y/N]: ");
    io::stdout().flush().ok();
    let yes = matches!(read_line()?.trim(), "y" | "Y" | "yes" | "YES");
    restart_codex(yes, include_app_server)
}

fn update_bundle(store_path: &PathBuf, auth_path: &PathBuf) -> Result<()> {
    print!("Bundle path: ");
    io::stdout().flush().ok();
    let bundle_path = read_line()?;
    let bundle_path = shellexpand_tilde(bundle_path.trim());
    let accounts = import_bundle(&bundle_path, store_path, false)?;
    let active = active_imported_account(&accounts)
        .or_else(|| accounts.first())
        .context("bundle did not contain any accounts")?;
    write_auth_file(auth_path, active)?;
    if let Err(error) = hermes::apply_account_if_configured(active) {
        eprintln!("warning: Hermes sync failed after token bundle update: {error:#}");
    }
    println!(
        "Updated {} account(s); active account written to {}",
        accounts.len(),
        auth_path.display()
    );
    Ok(())
}

fn shellexpand_tilde(path: &str) -> PathBuf {
    if path == "~" {
        return std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(path));
    }
    if let Some(stripped) = path.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(stripped);
        }
    }
    PathBuf::from(path)
}

fn print_readiness(store_path: &PathBuf, auth_path: &PathBuf) -> Result<()> {
    let report = readiness::check(store_path, auth_path)?;
    println!();
    println!("╭─ Auto-swap readiness ─────────────────────────────");
    println!(
        "│ {} {}",
        if report.ready { "✅" } else { "⚠️ " },
        report.summary
    );
    println!(
        "│ Accounts: {} | Active: {} | Ready candidates: {}",
        report.account_count,
        report.active_email.as_deref().unwrap_or("none"),
        report.ready_candidate_count
    );
    println!(
        "│ Auth writable: {} | Daemon: {} | Live CLI sessions: {} | App-servers: {}",
        yes_no(report.auth_writable),
        yes_no(report.daemon_running),
        report.processes.len(),
        report.app_servers.len()
    );
    for process in &report.processes {
        println!(
            "│ pid={} hot-swap={} {}",
            process.pid,
            yes_no(process.hot_swap_ready),
            process.executable
        );
    }
    for process in &report.app_servers {
        println!(
            "│ app-server pid={} hot-swap={} {}",
            process.pid,
            yes_no(process.hot_swap_ready),
            process.executable
        );
    }
    if !report.issues.is_empty() {
        println!("│ Issues:");
        for issue in &report.issues {
            println!("│ - {issue}");
        }
    }
    println!("╰──────────────────────────────────────────────────");
    Ok(())
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

fn choose_swap(store_path: &PathBuf, auth_path: &PathBuf) -> Result<()> {
    let accounts = load_accounts(store_path)?;
    let active = active_account(&accounts).map(|account| account.account_id.as_str());
    for (index, account) in accounts.iter().enumerate() {
        let marker = if Some(account.account_id.as_str()) == active {
            "*"
        } else {
            " "
        };
        println!("{}) {} {}", index + 1, marker, account.email);
    }
    print!("Account number/email/id: ");
    io::stdout().flush().ok();
    let selector = read_line()?;
    let trimmed = selector.trim();
    if let Ok(index) = trimmed.parse::<usize>() {
        let account = accounts
            .get(index.saturating_sub(1))
            .context("account number out of range")?;
        swap(store_path, auth_path, &account.account_id)
    } else {
        swap(store_path, auth_path, trimmed)
    }
}

fn read_line() -> Result<String> {
    let mut line = String::new();
    io::stdin()
        .read_line(&mut line)
        .context("failed to read terminal input")?;
    Ok(line)
}
