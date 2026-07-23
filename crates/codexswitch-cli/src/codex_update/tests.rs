#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn automatic_update_test_state(status: UpdateStatus, now: DateTime<Utc>) -> CodexUpdateState {
        CodexUpdateState {
            status,
            last_checked_at: Some(now),
            latest_stable_version: Some("0.145.0".to_string()),
            installed_version: Some("0.144.1".to_string()),
            installed_artifact_manifest_sha256: None,
            prepared_version: None,
            prepared_source_path: None,
            prepared_binary_path: None,
            prepared_artifact_manifest_sha256: None,
            failed_prepare_version: None,
            prepare_retry_not_before: None,
            failed_install_version: None,
            install_retry_not_before: None,
            cleanup_pending_target_path: None,
            unresolved_failure: None,
            install_transaction: None,
            error: None,
            updated_at: now,
        }
    }

    fn automatic_update_test_time() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 12, 12, 0, 0)
            .single()
            .unwrap()
    }

    fn test_build_target_provenance(
        version: &str,
        source_fingerprint: &str,
        recipe_fingerprint: &str,
        refreshed_at: DateTime<Utc>,
    ) -> BuildTargetProvenance {
        BuildTargetProvenance {
            schema_version: BUILD_TARGET_PROVENANCE_SCHEMA,
            version: version.to_string(),
            source_fingerprint: source_fingerprint.to_string(),
            build_recipe_fingerprint: recipe_fingerprint.to_string(),
            refreshed_at,
        }
    }

    fn linux_automatic_context(available_bytes: u64) -> AutomaticUpdateContext {
        AutomaticUpdateContext {
            platform: HostPlatform::Linux,
            policy: AutomaticUpdatePolicy::PrepareOnly,
            available_bytes,
        }
    }

    fn macos_automatic_context(available_bytes: u64) -> AutomaticUpdateContext {
        AutomaticUpdateContext {
            platform: HostPlatform::MacOs,
            policy: AutomaticUpdatePolicy::MetadataOnly,
            available_bytes,
        }
    }

    struct FakeDaemonArtifactProbe {
        reservation: RuntimeActivityObservation,
        pid_record: RuntimeActivityObservation,
        exact_process_scan: RuntimeActivityObservation,
        socket: RuntimeActivityObservation,
    }

    impl DaemonArtifactProbe for FakeDaemonArtifactProbe {
        fn reservation(&mut self) -> RuntimeActivityObservation {
            self.reservation.clone()
        }

        fn pid_record(&mut self) -> RuntimeActivityObservation {
            self.pid_record.clone()
        }

        fn exact_process_scan(&mut self) -> RuntimeActivityObservation {
            self.exact_process_scan.clone()
        }

        fn socket(&mut self) -> RuntimeActivityObservation {
            self.socket.clone()
        }
    }

    fn inactive_runtime_activity() -> ManagedRuntimeActivity {
        ManagedRuntimeActivity {
            systemd_unit: RuntimeActivityObservation::Inactive,
            app_server_daemon: RuntimeActivityObservation::Inactive,
        }
    }

    fn write_test_runtime(
        directory: &Path,
        version: &str,
        current_contract: bool,
    ) -> Result<PathBuf> {
        fs::create_dir_all(directory)?;
        let codex = directory.join("codex");
        let current_markers = if current_contract {
            "codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3 codexswitch-hotswap-headless-idle-v1"
        } else {
            "legacy-desktop-auth-reload-contract"
        };
        fs::write(
            &codex,
            format!(
                "#!/bin/sh\n# sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-hotswap-cli-contract-v3 Usage: /goal <objective> {current_markers}\necho 'codex-cli {version}'\n"
            ),
        )?;
        set_executable(&codex)?;
        let helper = directory.join("codex-code-mode-host");
        fs::write(&helper, b"host")?;
        set_executable(&helper)?;
        Ok(codex)
    }

    fn test_systemd_expectation() -> SystemdOwnerExpectation {
        SystemdOwnerExpectation {
            fragment_path: PathBuf::from(
                "/home/test/.config/systemd/user/signul-codex-app-server.service",
            ),
            exec_argv: vec![
                "/usr/bin/flock",
                "--shared",
                "--no-fork",
                "/home/test/.local/share/codexswitch/runtime-start-install.lock",
                "/usr/bin/flock",
                "--exclusive",
                "--nonblock",
                "--no-fork",
                "/home/test/.codex/app-server-daemon/app-server.pid.lock",
                "/home/test/.local/share/codexswitch/current/patched-codex/codex",
                "app-server",
                "--remote-control",
                "--listen",
                "ws://127.0.0.1:8390",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
        }
    }

    fn test_systemd_show(active_state: &str) -> Vec<u8> {
        let main_pid = match active_state {
            "active" | "activating" | "reloading" | "deactivating" => "4242",
            _ => "0",
        };
        test_systemd_show_with_main_pid(active_state, main_pid)
    }

    fn test_systemd_show_with_main_pid(active_state: &str, main_pid: &str) -> Vec<u8> {
        let expectation = test_systemd_expectation();
        format!(
            "LoadState=loaded\nActiveState={active_state}\nFragmentPath={}\nExecStart={{ path=/usr/bin/flock ; argv[]={} ; ignore_errors=no ; }}\nMainPID={main_pid}\n",
            expectation.fragment_path.display(),
            expectation.exec_argv.join(" ")
        )
        .into_bytes()
    }

    #[test]
    fn systemd_not_found_and_ambiguous_results_are_unknown() {
        let expectation = test_systemd_expectation();
        assert!(matches!(
            systemd_activity_from_probe(false, Some(4), b"", b"", &expectation),
            RuntimeActivityObservation::Unknown(_)
        ));
        assert!(matches!(
            systemd_activity_from_probe(false, Some(1), b"", b"", &expectation),
            RuntimeActivityObservation::Unknown(_)
        ));
        assert!(matches!(
            systemd_activity_from_probe(false, None, b"", b"", &expectation),
            RuntimeActivityObservation::Unknown(_)
        ));
        assert!(matches!(
            systemd_activity_from_probe(true, Some(0), b"malformed\n", b"", &expectation),
            RuntimeActivityObservation::Unknown(_)
        ));
        assert!(matches!(
            systemd_activity_from_probe(
                true,
                Some(0),
                &test_systemd_show("failed"),
                b"",
                &expectation,
            ),
            RuntimeActivityObservation::Unknown(_)
        ));
        assert_eq!(
            systemd_activity_from_probe(
                true,
                Some(0),
                &test_systemd_show("active"),
                b"",
                &expectation,
            ),
            RuntimeActivityObservation::Active
        );
        assert_eq!(
            systemd_activity_from_probe(
                true,
                Some(0),
                &test_systemd_show("inactive"),
                b"",
                &expectation,
            ),
            RuntimeActivityObservation::Inactive
        );
        assert!(matches!(
            systemd_activity_from_probe(
                true,
                Some(0),
                &test_systemd_show_with_main_pid("inactive", "4242"),
                b"",
                &expectation,
            ),
            RuntimeActivityObservation::Unknown(_)
        ));
        assert!(matches!(
            systemd_activity_from_probe(
                true,
                Some(0),
                &test_systemd_show_with_main_pid("inactive", "not-a-pid"),
                b"",
                &expectation,
            ),
            RuntimeActivityObservation::Unknown(_)
        ));
        assert!(matches!(
            systemd_activity_from_probe(
                true,
                Some(0),
                &test_systemd_show("inactive"),
                b"warning",
                &expectation,
            ),
            RuntimeActivityObservation::Unknown(_)
        ));
    }

    #[test]
    fn systemd_observer_seam_classifies_bounded_command_results() {
        let expectation = test_systemd_expectation();
        let cases = [
            (
                CommandProbeOutput {
                    success: true,
                    exit_code: Some(0),
                    stdout: test_systemd_show("active"),
                    stderr: Vec::new(),
                },
                RuntimeActivityObservation::Active,
            ),
            (
                CommandProbeOutput {
                    success: true,
                    exit_code: Some(0),
                    stdout: test_systemd_show("inactive"),
                    stderr: Vec::new(),
                },
                RuntimeActivityObservation::Inactive,
            ),
            (
                CommandProbeOutput {
                    success: false,
                    exit_code: Some(4),
                    stdout: b"unknown\n".to_vec(),
                    stderr: b"not found\n".to_vec(),
                },
                RuntimeActivityObservation::Unknown(String::new()),
            ),
            (
                CommandProbeOutput {
                    success: true,
                    exit_code: Some(0),
                    stdout: test_systemd_show("inactive"),
                    stderr: b"ambiguous warning\n".to_vec(),
                },
                RuntimeActivityObservation::Unknown(String::new()),
            ),
        ];

        for (output, expected) in cases {
            let observed = observe_managed_systemd_unit_activity_with(&expectation, || Ok(output));
            match expected {
                RuntimeActivityObservation::Unknown(_) => {
                    assert!(matches!(observed, RuntimeActivityObservation::Unknown(_)));
                }
                expected => assert_eq!(observed, expected),
            }
        }
        assert!(matches!(
            observe_managed_systemd_unit_activity_with(&expectation, || {
                Err(anyhow::anyhow!("bounded systemctl probe timed out"))
            }),
            RuntimeActivityObservation::Unknown(_)
        ));

        let mut drifted = test_systemd_show("inactive");
        drifted.extend_from_slice(b"FragmentPath=/tmp/spoof.service\n");
        assert!(matches!(
            observe_managed_systemd_unit_activity_with(&expectation, || {
                Ok(CommandProbeOutput {
                    success: true,
                    exit_code: Some(0),
                    stdout: drifted,
                    stderr: Vec::new(),
                })
            }),
            RuntimeActivityObservation::Unknown(_)
        ));
    }

    #[test]
    fn daemon_artifact_observer_seam_is_fail_closed_for_lock_pid_process_and_socket() {
        let inactive = RuntimeActivityObservation::Inactive;
        let cases = [
            FakeDaemonArtifactProbe {
                reservation: inactive.clone(),
                pid_record: inactive.clone(),
                exact_process_scan: inactive.clone(),
                socket: inactive.clone(),
            },
            FakeDaemonArtifactProbe {
                reservation: RuntimeActivityObservation::Active,
                pid_record: inactive.clone(),
                exact_process_scan: inactive.clone(),
                socket: inactive.clone(),
            },
            FakeDaemonArtifactProbe {
                reservation: RuntimeActivityObservation::Unknown("lock probe failed".to_string()),
                pid_record: inactive.clone(),
                exact_process_scan: inactive.clone(),
                socket: inactive.clone(),
            },
            FakeDaemonArtifactProbe {
                reservation: inactive.clone(),
                pid_record: RuntimeActivityObservation::Active,
                exact_process_scan: inactive.clone(),
                socket: inactive.clone(),
            },
            FakeDaemonArtifactProbe {
                reservation: inactive.clone(),
                pid_record: RuntimeActivityObservation::Unknown("pid record malformed".to_string()),
                exact_process_scan: inactive.clone(),
                socket: inactive.clone(),
            },
            FakeDaemonArtifactProbe {
                reservation: inactive.clone(),
                pid_record: inactive.clone(),
                exact_process_scan: RuntimeActivityObservation::Active,
                socket: inactive.clone(),
            },
            FakeDaemonArtifactProbe {
                reservation: inactive.clone(),
                pid_record: inactive.clone(),
                exact_process_scan: inactive.clone(),
                socket: RuntimeActivityObservation::Unknown("socket exists".to_string()),
            },
        ];
        let expected = [
            "inactive", "active", "unknown", "active", "unknown", "active", "unknown",
        ];

        for (mut probe, expected) in cases.into_iter().zip(expected) {
            let observed = observe_managed_daemon_artifacts_with(&mut probe);
            match expected {
                "inactive" => assert_eq!(observed, RuntimeActivityObservation::Inactive),
                "active" => assert_eq!(observed, RuntimeActivityObservation::Active),
                _ => assert!(matches!(observed, RuntimeActivityObservation::Unknown(_))),
            }
        }
    }

    #[test]
    fn exact_daemon_identity_requires_inode_command_and_stable_process_start() {
        let expected_argv0 = Path::new("/runtime/codex");
        let daemon = b"/runtime/codex\0app-server\0--listen\0unix://\0";
        let not_daemon = b"/runtime/codex\0exec\0--listen\0unix://\0";
        let cases = [
            (10, 20, 10, 20, &daemon[..], 30, 30, true),
            (10, 20, 11, 20, &daemon[..], 30, 30, false),
            (10, 20, 10, 21, &daemon[..], 30, 30, false),
            (10, 20, 10, 20, &not_daemon[..], 30, 30, false),
            (10, 20, 10, 20, &daemon[..], 30, 31, false),
        ];

        for (expected_dev, expected_ino, dev, ino, command, before, after, expected) in cases {
            assert_eq!(
                exact_managed_daemon_identity_matches(
                    expected_dev,
                    expected_ino,
                    dev,
                    ino,
                    expected_argv0,
                    command,
                    before,
                    after,
                ),
                expected
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn process_observer_rejects_hardlink_path_and_spoofed_argv() -> Result<()> {
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir()?;
        let runtime = temp.path().join("runtime/codex");
        fs::create_dir_all(runtime.parent().unwrap())?;
        fs::write(&runtime, b"runtime")?;
        let hardlink = temp.path().join("runtime/codex-hardlink");
        fs::hard_link(&runtime, &hardlink)?;
        let proc_root = temp.path().join("proc");
        let process = proc_root.join("42");
        fs::create_dir_all(&process)?;
        let stat_line = format!("42 (codex) {}\n", vec!["1"; 20].join(" "));
        fs::write(process.join("stat"), stat_line)?;
        fs::write(
            process.join("cmdline"),
            [
                runtime.as_os_str().as_bytes(),
                b"app-server",
                b"--listen",
                b"unix://",
            ]
            .iter()
            .flat_map(|argument| argument.iter().copied().chain(std::iter::once(0)))
            .collect::<Vec<_>>(),
        )?;
        symlink(&runtime, process.join("exe"))?;
        let metadata = fs::metadata(&runtime)?;
        let canonical = fs::canonicalize(&runtime)?;

        assert_eq!(
            linux_process_matches_exact_managed_daemon_with_metadata(
                &proc_root, 42, &runtime, &canonical, &metadata,
            )?,
            ExactManagedProcessObservation::Active
        );

        fs::remove_file(process.join("exe"))?;
        symlink(&hardlink, process.join("exe"))?;
        assert!(matches!(
            linux_process_matches_exact_managed_daemon_with_metadata(
                &proc_root, 42, &runtime, &canonical, &metadata,
            )?,
            ExactManagedProcessObservation::IdentityDrift(_)
        ));

        fs::remove_file(process.join("exe"))?;
        let replacement = temp.path().join("runtime/replacement-codex");
        fs::write(&replacement, b"replacement runtime")?;
        symlink(&replacement, process.join("exe"))?;
        let replaced = linux_process_matches_exact_managed_daemon_with_metadata(
            &proc_root, 42, &runtime, &canonical, &metadata,
        )?;
        assert!(matches!(
            &replaced,
            ExactManagedProcessObservation::IdentityDrift(reason)
                if reason.contains("exact managed argv on a replaced executable inode")
        ));
        assert_ne!(replaced, ExactManagedProcessObservation::Unrelated);

        fs::remove_file(process.join("exe"))?;
        symlink(&runtime, process.join("exe"))?;
        fs::write(
            process.join("cmdline"),
            [
                runtime.as_os_str().as_bytes(),
                b"app-server",
                b"--listen",
                b"tcp://",
            ]
            .iter()
            .flat_map(|argument| argument.iter().copied().chain(std::iter::once(0)))
            .collect::<Vec<_>>(),
        )?;
        assert!(matches!(
            linux_process_matches_exact_managed_daemon_with_metadata(
                &proc_root, 42, &runtime, &canonical, &metadata,
            )?,
            ExactManagedProcessObservation::IdentityDrift(_)
        ));
        Ok(())
    }

    #[test]
    fn missing_daemon_executable_and_artifacts_fail_closed_without_replacement() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let observation = observe_managed_app_server_daemon_activity_at(
            HostPlatform::Linux,
            &temp.path().join("missing-codex"),
            &temp.path().join("missing-codex-home"),
        );
        assert!(matches!(
            &observation,
            RuntimeActivityObservation::Unknown(_)
        ));

        let replacements = std::cell::Cell::new(0);
        let activity = ManagedRuntimeActivity {
            systemd_unit: RuntimeActivityObservation::Inactive,
            app_server_daemon: observation,
        };
        let outcome = install_offline_if_inactive(&activity, || {
            replacements.set(replacements.get() + 1);
            Ok(())
        })?;

        assert!(matches!(outcome, OfflineInstallOutcome::Staged(_)));
        assert_eq!(replacements.get(), 0);
        Ok(())
    }

    #[test]
    fn daemon_observer_entrypoint_uses_injected_bounded_command_probe() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let runtime = temp.path().join("codex");
        fs::write(&runtime, b"runtime")?;
        set_executable(&runtime)?;
        let codex_home = temp.path().join("codex-home");

        let active = observe_managed_app_server_daemon_activity_at_with_probe(
            HostPlatform::Other,
            &runtime,
            &codex_home,
            false,
            |_| {
                Ok(CommandProbeOutput {
                    success: true,
                    exit_code: Some(0),
                    stdout: br#"{"status":"running"}"#.to_vec(),
                    stderr: Vec::new(),
                })
            },
        );
        assert_eq!(active, RuntimeActivityObservation::Active);

        let ambiguous = observe_managed_app_server_daemon_activity_at_with_probe(
            HostPlatform::Other,
            &runtime,
            &codex_home,
            false,
            |_| {
                Ok(CommandProbeOutput {
                    success: true,
                    exit_code: Some(0),
                    stdout: br#"{"status":"stopped"}"#.to_vec(),
                    stderr: b"probe warning\n".to_vec(),
                })
            },
        );
        assert!(matches!(ambiguous, RuntimeActivityObservation::Unknown(_)));

        let failed = observe_managed_app_server_daemon_activity_at_with_probe(
            HostPlatform::Other,
            &runtime,
            &codex_home,
            false,
            |_| Err(anyhow::anyhow!("bounded daemon probe timed out")),
        );
        assert!(matches!(failed, RuntimeActivityObservation::Unknown(_)));
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn missing_daemon_executable_still_observes_held_reservation_lock() -> Result<()> {
        use std::os::fd::AsRawFd;

        let temp = tempfile::tempdir()?;
        let codex_home = temp.path().join("codex-home");
        let state_dir = codex_home.join("app-server-daemon");
        fs::create_dir_all(&state_dir)?;
        let lock_path = state_dir.join("app-server.pid.lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)?;
        assert_eq!(
            unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
            0
        );

        let observation = observe_managed_app_server_daemon_activity_at(
            HostPlatform::Linux,
            &temp.path().join("missing-codex"),
            &codex_home,
        );

        assert_eq!(observation, RuntimeActivityObservation::Active);
        assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
        Ok(())
    }

    #[test]
    fn racing_systemd_start_after_initial_observation_prevents_rename() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let start_guard = temp.path().join("runtime-start-install.lock");
        let daemon_guard = temp
            .path()
            .join("codex-home/app-server-daemon/app-server.pid.lock");
        let destination = temp.path().join("codex");
        let staged = temp.path().join("codex.staged");
        fs::write(&destination, b"old")?;
        let held_service_lock = std::cell::RefCell::new(None);
        let renames = std::cell::Cell::new(0);

        let outcome = install_staged_if_still_inactive(
            &inactive_runtime_activity(),
            || {
                fs::write(&staged, b"new")?;
                let lock =
                    AdvisoryFileLock::try_acquire_at(&start_guard, AdvisoryLockMode::Shared)?
                        .context("simulated systemd start did not acquire shared guard")?;
                *held_service_lock.borrow_mut() = Some(lock);
                Ok(staged.clone())
            },
            || RuntimeCommitGuards::try_acquire_at(&start_guard, &daemon_guard),
            |_| inactive_runtime_activity(),
            |staged, _| {
                renames.set(renames.get() + 1);
                fs::rename(staged, &destination)?;
                Ok(())
            },
        )?;

        assert!(matches!(outcome, OfflineInstallOutcome::Staged(_)));
        assert_eq!(renames.get(), 0);
        assert_eq!(fs::read(&destination)?, b"old");
        Ok(())
    }

    #[test]
    fn linux_runtime_files_are_pre_staged_before_commit() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let prepared_dir = temp.path().join("prepared");
        let data_dir = temp.path().join("data");
        let installed_dir = data_dir.join("patched-codex");
        fs::create_dir_all(&prepared_dir)?;
        fs::create_dir_all(&installed_dir)?;
        let prepared = prepared_dir.join("codex");
        let prepared_helper = prepared_dir.join("codex-code-mode-host");
        let installed = installed_dir.join("codex");
        let installed_helper = installed_dir.join("codex-code-mode-host");
        fs::write(&prepared, b"new runtime")?;
        fs::write(&prepared_helper, b"new helper")?;
        fs::write(&installed, b"old runtime")?;
        fs::write(&installed_helper, b"old helper")?;

        let staged = StagedLinuxRuntimeInstall::prepare(&prepared, &installed)?;

        assert_eq!(fs::read(&installed)?, b"old runtime");
        assert_eq!(fs::read(&installed_helper)?, b"old helper");
        assert!(staged.runtime_temp.is_file());
        assert!(staged.helper_temp.is_file());
        let state_path = data_dir.join("codex-cli-update.json");
        let journal_path = data_dir.join(RUNTIME_INSTALL_JOURNAL);
        let mut state = automatic_update_test_state(UpdateStatus::ReadyToInstall, Utc::now());
        state.prepared_version = Some("0.145.0".to_string());
        staged.commit_journaled_with(
            &journal_path,
            &state_path,
            &mut state,
            "0.145.0",
            |_runtime, _helper, _version| Ok(()),
            |_| Ok(()),
        )?;
        assert_eq!(fs::read(&installed)?, b"new runtime");
        assert_eq!(fs::read(&installed_helper)?, b"new helper");
        assert!(!journal_path.exists());
        assert!(state.install_transaction.is_none());
        Ok(())
    }

    #[test]
    fn runtime_pair_faults_recover_without_mixed_generation() -> Result<()> {
        for fault_point in [
            RuntimeInstallFaultPoint::AfterHelperRename,
            RuntimeInstallFaultPoint::AfterRuntimeRename,
            RuntimeInstallFaultPoint::AfterRuntimeDirectorySync,
            RuntimeInstallFaultPoint::AfterReadback,
            RuntimeInstallFaultPoint::AfterStateSave,
            RuntimeInstallFaultPoint::AfterCleanup,
            RuntimeInstallFaultPoint::AfterStateFinalized,
        ] {
            let temp = tempfile::tempdir()?;
            let data_dir = temp.path().join("data");
            let installed_dir = data_dir.join("patched-codex");
            let prepared_dir = temp.path().join("prepared");
            fs::create_dir_all(&installed_dir)?;
            fs::create_dir_all(&prepared_dir)?;
            let installed = installed_dir.join("codex");
            let helper = installed_dir.join("codex-code-mode-host");
            let prepared = prepared_dir.join("codex");
            let prepared_helper = prepared_dir.join("codex-code-mode-host");
            fs::write(&installed, b"old-runtime")?;
            fs::write(&helper, b"old-helper")?;
            fs::write(&prepared, b"new-runtime")?;
            fs::write(&prepared_helper, b"new-helper")?;
            let state_path = data_dir.join("codex-cli-update.json");
            let journal_path = data_dir.join(RUNTIME_INSTALL_JOURNAL);
            let mut state = automatic_update_test_state(UpdateStatus::ReadyToInstall, Utc::now());
            state.prepared_version = Some("0.145.0".to_string());

            let error = StagedLinuxRuntimeInstall::prepare(&prepared, &installed)?
                .commit_journaled_with(
                    &journal_path,
                    &state_path,
                    &mut state,
                    "0.145.0",
                    |_runtime, _helper, _version| Ok(()),
                    |point| {
                        if point == fault_point {
                            bail!("injected fault at {point:?}");
                        }
                        Ok(())
                    },
                )
                .expect_err("fault must interrupt the transaction");
            assert!(error.to_string().contains("injected fault"));
            assert!(journal_path.is_file());

            let mut replayed = load_state_at(&state_path)?;
            let outcome = recover_runtime_install_transaction_at(
                &journal_path,
                &state_path,
                &mut replayed,
                &installed,
                &helper,
                |_runtime, _helper, _version| Ok(()),
            )?;
            let committed = matches!(
                fault_point,
                RuntimeInstallFaultPoint::AfterStateSave
                    | RuntimeInstallFaultPoint::AfterCleanup
                    | RuntimeInstallFaultPoint::AfterStateFinalized
            );
            assert_eq!(
                outcome,
                if committed {
                    RuntimeInstallRecoveryOutcome::Committed
                } else {
                    RuntimeInstallRecoveryOutcome::RolledBack
                }
            );
            assert_eq!(
                fs::read(&installed)?,
                if committed {
                    b"new-runtime".as_slice()
                } else {
                    b"old-runtime".as_slice()
                }
            );
            assert_eq!(
                fs::read(&helper)?,
                if committed {
                    b"new-helper".as_slice()
                } else {
                    b"old-helper".as_slice()
                }
            );
            assert!(!journal_path.exists());
            assert!(replayed.install_transaction.is_none());
        }
        Ok(())
    }

    #[test]
    fn start_guards_cover_every_runtime_transaction_checkpoint() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let data_dir = temp.path().join("data");
        let installed_dir = data_dir.join("patched-codex");
        let prepared_dir = temp.path().join("prepared");
        fs::create_dir_all(&installed_dir)?;
        fs::create_dir_all(&prepared_dir)?;
        let installed = installed_dir.join("codex");
        let helper = installed_dir.join("codex-code-mode-host");
        let prepared = prepared_dir.join("codex");
        fs::write(&installed, b"old-runtime")?;
        fs::write(&helper, b"old-helper")?;
        fs::write(&prepared, b"new-runtime")?;
        fs::write(prepared_dir.join("codex-code-mode-host"), b"new-helper")?;
        let start_guard = data_dir.join(RUNTIME_START_INSTALL_GUARD);
        let daemon_guard = temp
            .path()
            .join("codex-home/app-server-daemon/app-server.pid.lock");
        let state_path = data_dir.join("codex-cli-update.json");
        let journal_path = data_dir.join(RUNTIME_INSTALL_JOURNAL);
        let mut state = automatic_update_test_state(UpdateStatus::ReadyToInstall, Utc::now());
        state.prepared_version = Some("0.145.0".to_string());
        let checkpoints = std::cell::Cell::new(0_u8);

        let outcome = install_staged_if_still_inactive(
            &inactive_runtime_activity(),
            || StagedLinuxRuntimeInstall::prepare(&prepared, &installed),
            || RuntimeCommitGuards::try_acquire_at(&start_guard, &daemon_guard),
            |_| inactive_runtime_activity(),
            |staged, _guards| {
                staged.commit_journaled_with(
                    &journal_path,
                    &state_path,
                    &mut state,
                    "0.145.0",
                    |_runtime, _helper, _version| Ok(()),
                    |_point| {
                        assert!(AdvisoryFileLock::try_acquire_at(
                            &start_guard,
                            AdvisoryLockMode::Shared,
                        )?
                        .is_none());
                        assert!(AdvisoryFileLock::try_acquire_at(
                            &daemon_guard,
                            AdvisoryLockMode::Exclusive,
                        )?
                        .is_none());
                        checkpoints.set(checkpoints.get() + 1);
                        Ok(())
                    },
                )
            },
        )?;

        assert_eq!(outcome, OfflineInstallOutcome::Installed);
        assert_eq!(checkpoints.get(), 7);
        assert_eq!(fs::read(&installed)?, b"new-runtime");
        assert_eq!(fs::read(&helper)?, b"new-helper");
        Ok(())
    }

    #[test]
    fn committed_install_replay_preserves_activation_failure() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let data_dir = temp.path().join("data");
        let installed_dir = data_dir.join("patched-codex");
        let prepared_dir = temp.path().join("prepared");
        fs::create_dir_all(&installed_dir)?;
        fs::create_dir_all(&prepared_dir)?;
        let installed = installed_dir.join("codex");
        let helper = installed_dir.join("codex-code-mode-host");
        let prepared = prepared_dir.join("codex");
        fs::write(&installed, b"old-runtime")?;
        fs::write(&helper, b"old-helper")?;
        fs::write(&prepared, b"new-runtime")?;
        fs::write(prepared_dir.join("codex-code-mode-host"), b"new-helper")?;
        let state_path = data_dir.join("codex-cli-update.json");
        let journal_path = data_dir.join(RUNTIME_INSTALL_JOURNAL);
        let mut state = automatic_update_test_state(UpdateStatus::Failed, Utc::now());
        state.error = Some("activation acknowledgement failed".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Activation,
            Utc::now(),
            Some("0.145.0".to_string()),
            None,
        );

        StagedLinuxRuntimeInstall::prepare(&prepared, &installed)?
            .commit_journaled_with(
                &journal_path,
                &state_path,
                &mut state,
                "0.145.0",
                |_runtime, _helper, _version| Ok(()),
                |point| {
                    if point == RuntimeInstallFaultPoint::AfterStateSave {
                        bail!("crash after state save");
                    }
                    Ok(())
                },
            )
            .expect_err("fault must leave a committed journal");
        let mut replayed = load_state_at(&state_path)?;
        recover_runtime_install_transaction_at(
            &journal_path,
            &state_path,
            &mut replayed,
            &installed,
            &helper,
            |_runtime, _helper, _version| Ok(()),
        )?;

        assert_eq!(replayed.status, UpdateStatus::Failed);
        assert_eq!(
            replayed.error.as_deref(),
            Some("activation acknowledgement failed")
        );
        assert_eq!(
            replayed
                .unresolved_failure
                .as_ref()
                .map(|failure| failure.kind),
            Some(UpdateFailureKind::Activation)
        );
        assert_eq!(replayed.installed_version.as_deref(), Some("0.145.0"));
        Ok(())
    }

    #[test]
    fn racing_daemon_start_after_initial_observation_prevents_rename() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let start_guard = temp.path().join("runtime-start-install.lock");
        let daemon_guard = temp
            .path()
            .join("codex-home/app-server-daemon/app-server.pid.lock");
        let destination = temp.path().join("codex");
        let staged = temp.path().join("codex.staged");
        fs::write(&destination, b"old")?;
        let held_daemon_lock = std::cell::RefCell::new(None);
        let renames = std::cell::Cell::new(0);

        let outcome = install_staged_if_still_inactive(
            &inactive_runtime_activity(),
            || {
                fs::write(&staged, b"new")?;
                let lock =
                    AdvisoryFileLock::try_acquire_at(&daemon_guard, AdvisoryLockMode::Exclusive)?
                        .context("simulated daemon start did not acquire reservation")?;
                *held_daemon_lock.borrow_mut() = Some(lock);
                Ok(staged.clone())
            },
            || RuntimeCommitGuards::try_acquire_at(&start_guard, &daemon_guard),
            |_| inactive_runtime_activity(),
            |staged, _| {
                renames.set(renames.get() + 1);
                fs::rename(staged, &destination)?;
                Ok(())
            },
        )?;

        assert!(matches!(outcome, OfflineInstallOutcome::Staged(_)));
        assert_eq!(renames.get(), 0);
        assert_eq!(fs::read(&destination)?, b"old");
        Ok(())
    }

    #[test]
    fn runtime_guards_remain_held_through_final_observation_and_commit() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let start_guard = temp.path().join("runtime-start-install.lock");
        let daemon_guard = temp
            .path()
            .join("codex-home/app-server-daemon/app-server.pid.lock");
        let observed_with_guards = std::cell::Cell::new(false);
        let committed_with_guards = std::cell::Cell::new(false);

        let outcome = install_staged_if_still_inactive(
            &inactive_runtime_activity(),
            || Ok(()),
            || RuntimeCommitGuards::try_acquire_at(&start_guard, &daemon_guard),
            |_| {
                observed_with_guards.set(
                    matches!(
                        AdvisoryFileLock::try_acquire_at(&start_guard, AdvisoryLockMode::Shared),
                        Ok(None)
                    ) && matches!(
                        AdvisoryFileLock::try_acquire_at(
                            &daemon_guard,
                            AdvisoryLockMode::Exclusive
                        ),
                        Ok(None)
                    ),
                );
                inactive_runtime_activity()
            },
            |(), _| {
                committed_with_guards.set(
                    AdvisoryFileLock::try_acquire_at(&start_guard, AdvisoryLockMode::Shared)?
                        .is_none()
                        && AdvisoryFileLock::try_acquire_at(
                            &daemon_guard,
                            AdvisoryLockMode::Exclusive,
                        )?
                        .is_none(),
                );
                Ok(())
            },
        )?;

        assert_eq!(outcome, OfflineInstallOutcome::Installed);
        assert!(observed_with_guards.get());
        assert!(committed_with_guards.get());
        Ok(())
    }

    #[test]
    fn ready_to_install_with_active_systemd_replaces_nothing() -> Result<()> {
        let replacements = std::cell::Cell::new(0);
        let activity = ManagedRuntimeActivity {
            systemd_unit: RuntimeActivityObservation::Active,
            app_server_daemon: RuntimeActivityObservation::Inactive,
        };

        let outcome = install_offline_if_inactive(&activity, || {
            replacements.set(replacements.get() + 1);
            Ok(())
        })?;

        assert!(matches!(outcome, OfflineInstallOutcome::Staged(_)));
        assert_eq!(replacements.get(), 0);
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn ready_to_install_with_active_daemon_replaces_nothing_and_never_restarts() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let fake_codex = temp.path().join("codex");
        let invocation_log = temp.path().join("invocations.log");
        fs::write(
            &fake_codex,
            format!(
                r#"#!/bin/sh
printf '%s\n' "$*" >> '{}'
case "$*" in
  "app-server daemon version")
    printf '%s\n' '{{"status":"running","appServerVersion":"0.141.0"}}'
    ;;
  *)
    exit 64
    ;;
esac
"#,
                invocation_log.display()
            ),
        )?;
        set_executable(&fake_codex)?;

        let replacements = std::cell::Cell::new(0);
        let activity = ManagedRuntimeActivity {
            systemd_unit: RuntimeActivityObservation::Inactive,
            app_server_daemon: observe_managed_app_server_daemon_activity(
                HostPlatform::Linux,
                &fake_codex,
            ),
        };
        let outcome = install_offline_if_inactive(&activity, || {
            replacements.set(replacements.get() + 1);
            Ok(())
        })?;

        assert!(matches!(outcome, OfflineInstallOutcome::Staged(_)));
        assert_eq!(replacements.get(), 0);
        assert_eq!(
            fs::read_to_string(invocation_log)?,
            "app-server daemon version\n"
        );
        Ok(())
    }

    #[test]
    fn explicit_inactive_install_replaces_once_with_no_restart_hook() -> Result<()> {
        let replacements = std::cell::Cell::new(0);
        let activity = ManagedRuntimeActivity {
            systemd_unit: RuntimeActivityObservation::Inactive,
            app_server_daemon: RuntimeActivityObservation::Inactive,
        };

        let outcome = install_offline_if_inactive(&activity, || {
            replacements.set(replacements.get() + 1);
            Ok(())
        })?;

        assert_eq!(outcome, OfflineInstallOutcome::Installed);
        assert_eq!(replacements.get(), 1);
        Ok(())
    }

    #[test]
    fn runtime_observation_failures_block_install_closed() -> Result<()> {
        let replacements = std::cell::Cell::new(0);
        let activity = ManagedRuntimeActivity {
            systemd_unit: RuntimeActivityObservation::Unknown("systemd unavailable".to_string()),
            app_server_daemon: RuntimeActivityObservation::Inactive,
        };

        let outcome = install_offline_if_inactive(&activity, || {
            replacements.set(replacements.get() + 1);
            Ok(())
        })?;

        assert!(matches!(outcome, OfflineInstallOutcome::Staged(_)));
        assert_eq!(replacements.get(), 0);
        Ok(())
    }

    #[test]
    fn app_server_unit_has_graceful_stop_contract() {
        let unit = include_str!("../../systemd/signul-codex-app-server.service");
        let exec_start = unit
            .lines()
            .find(|line| line.starts_with("ExecStart="))
            .expect("fixture must define ExecStart");
        assert!(exec_start.starts_with("ExecStart=/usr/bin/flock --shared --no-fork "));
        assert!(exec_start.contains(
            "runtime-start-install.lock /usr/bin/flock --exclusive --nonblock --no-fork \
             %h/.codex/app-server-daemon/app-server.pid.lock"
        ));
        assert!(unit.lines().any(|line| line == "KillSignal=SIGINT"));
        assert!(unit.lines().any(|line| line == "KillMode=mixed"));
        assert!(unit.lines().any(|line| line == "TimeoutStopSec=120"));
        assert!(unit.lines().any(|line| line == "SendSIGKILL=no"));
        assert!(!unit.lines().any(|line| line.starts_with("ExecStop=")));
        assert!(!unit.contains("local_thread_store_compression"));
    }

    #[test]
    fn updater_source_has_no_post_install_restart_path() {
        let source = [
            include_str!("../codex_update.rs"),
            include_str!("state.rs"),
            include_str!("transaction.rs"),
            include_str!("preparation.rs"),
            include_str!("retention.rs"),
            include_str!("runtime_discovery.rs"),
            include_str!("generated_systemd.rs"),
            include_str!("source_patching.rs"),
            include_str!("source_checkout.rs"),
            include_str!("source_app_server_template.rs"),
            include_str!("source_turn_template.rs"),
            include_str!("source_app_server_patching.rs"),
            include_str!("source_auth_patching.rs"),
            include_str!("source_websocket_patching.rs"),
            include_str!("source_patch_helpers.rs"),
            include_str!("../patched_codex.rs"),
        ]
        .join("\n");
        let forbidden = [
            ["restart_managed_app_servers_", "after_install"].concat(),
            ["restart_managed_app_server_daemon_", "if_running"].concat(),
            ["[\"app-server\", \"daemon\", \"", "restart", "\"]"].concat(),
            [".arg(\"", "restart", "\")"].concat(),
        ];
        for text in forbidden {
            assert!(
                !source.contains(text.as_str()),
                "obsolete restart path remains: {text}"
            );
        }
    }

    #[test]
    fn source_and_prepared_retention_preserves_active_current_and_rollback() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let data_dir = temp.path();
        let mut source_paths = Vec::new();
        for version in ["0.141.0", "0.142.0", "0.143.0", "0.144.0"] {
            let path = data_dir.join(format!("codex-source-stable-{version}"));
            fs::create_dir(&path)?;
            fs::write(path.join("source"), b"12345678")?;
            source_paths.push(path);
            std::thread::sleep(Duration::from_millis(2));
        }
        let mut state = automatic_update_test_state(UpdateStatus::Preparing, Utc::now());
        state.prepared_source_path = Some(source_paths[0].display().to_string());
        let mut protected = updater_protected_paths(&state, data_dir);
        let mut enumeration = RetentionEnumerationBudget::new(100);
        let sources = collect_source_trees(data_dir, 1024, &mut enumeration)?;
        protect_newest_pair(&sources, &mut protected);
        retain_updater_artifacts(
            sources,
            &protected,
            SystemTime::now() + Duration::from_secs(2),
            UpdaterRetentionPolicy {
                max_count: 3,
                max_total_bytes: 24,
                max_age: Duration::from_secs(1),
            },
            data_dir,
            "test source tree",
        )?;
        assert!(source_paths[0].exists(), "active source was pruned");
        assert!(!source_paths[1].exists(), "unprotected old source survived");
        assert!(source_paths[2].exists(), "rollback source was pruned");
        assert!(source_paths[3].exists(), "current source was pruned");

        let version_root = data_dir.join("prepared-codex/0.144.0");
        let mut generations = Vec::new();
        for attempt in ["a", "b", "c", "d"] {
            let path = version_root.join(attempt);
            fs::create_dir_all(&path)?;
            fs::write(path.join("codex"), b"12345678")?;
            generations.push(path);
            std::thread::sleep(Duration::from_millis(2));
        }
        state.prepared_version = Some("0.144.0".to_string());
        state.prepared_binary_path = Some(generations[0].join("codex").display().to_string());
        let mut protected = updater_protected_paths(&state, data_dir);
        let mut enumeration = RetentionEnumerationBudget::new(100);
        let prepared = collect_prepared_generations(data_dir, 1024, &mut enumeration)?;
        protect_newest_pair(&prepared, &mut protected);
        retain_updater_artifacts(
            prepared,
            &protected,
            SystemTime::now() + Duration::from_secs(2),
            UpdaterRetentionPolicy {
                max_count: 3,
                max_total_bytes: 24,
                max_age: Duration::from_secs(1),
            },
            data_dir,
            "test prepared generation",
        )?;
        assert!(generations[0].exists(), "active generation was pruned");
        assert!(
            !generations[1].exists(),
            "unprotected old generation survived"
        );
        assert!(generations[2].exists(), "rollback generation was pruned");
        assert!(generations[3].exists(), "current generation was pruned");
        Ok(())
    }

    #[test]
    fn updater_artifact_age_guard_prunes_at_exact_boundary() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let artifact_path = temp.path().join("codex-source-stable-0.141.0");
        fs::create_dir(&artifact_path)?;
        let modified = fs::metadata(&artifact_path)?.modified()?;
        let artifact = UpdaterArtifact {
            path: artifact_path.clone(),
            canonical_path: fs::canonicalize(&artifact_path)?,
            modified,
            bytes: 0,
        };
        let policy = UpdaterRetentionPolicy {
            max_count: 2,
            max_total_bytes: 1024,
            max_age: Duration::from_secs(60),
        };
        retain_updater_artifacts(
            vec![artifact.clone()],
            &HashSet::new(),
            modified + policy.max_age - Duration::from_nanos(1),
            policy,
            temp.path(),
            "test source tree",
        )?;
        assert!(artifact_path.exists());
        retain_updater_artifacts(
            vec![artifact],
            &HashSet::new(),
            modified + policy.max_age,
            policy,
            temp.path(),
            "test source tree",
        )?;
        assert!(!artifact_path.exists());
        Ok(())
    }

    #[test]
    fn retention_max_plus_one_fails_before_any_mutation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let first = temp.path().join("codex-source-stable-0.144.0");
        let second = temp.path().join("codex-source-stable-0.145.0");
        fs::create_dir(&first)?;
        fs::create_dir(&second)?;
        fs::write(first.join("source"), b"first")?;
        fs::write(second.join("source"), b"second")?;
        let mut enumeration = RetentionEnumerationBudget::new(1);

        let error = collect_source_trees(temp.path(), 1024, &mut enumeration)
            .expect_err("max + 1 must fail inventory");

        assert!(error.to_string().contains("before mutation"));
        assert_eq!(fs::read(first.join("source"))?, b"first");
        assert_eq!(fs::read(second.join("source"))?, b"second");
        Ok(())
    }

    #[test]
    fn source_and_prepared_retention_share_one_enumeration_budget() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let source = temp.path().join("codex-source-stable-0.145.0");
        fs::create_dir(&source)?;
        fs::write(source.join("source"), b"source")?;
        let prepared = temp.path().join("prepared-codex/0.145.0/attempt-a");
        fs::create_dir_all(&prepared)?;
        fs::write(prepared.join("codex"), b"runtime")?;
        let mut enumeration = RetentionEnumerationBudget::new(5);

        let _ = collect_source_trees(temp.path(), 1024, &mut enumeration)?;
        let error = collect_prepared_generations(temp.path(), 1024, &mut enumeration)
            .expect_err("the shared max + 1 inventory must fail");

        assert!(error.to_string().contains("before mutation"));
        assert_eq!(fs::read(source.join("source"))?, b"source");
        assert_eq!(fs::read(prepared.join("codex"))?, b"runtime");
        Ok(())
    }

    #[test]
    fn equal_timestamp_retention_uses_canonical_path_order() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let modified = SystemTime::UNIX_EPOCH + Duration::from_secs(10);
        let mut artifacts = Vec::new();
        for name in ["c", "a", "b"] {
            let path = temp.path().join(name);
            fs::create_dir(&path)?;
            artifacts.push(UpdaterArtifact {
                path: path.clone(),
                canonical_path: fs::canonicalize(&path)?,
                modified,
                bytes: 1,
            });
        }

        retain_updater_artifacts(
            artifacts,
            &HashSet::new(),
            modified,
            UpdaterRetentionPolicy {
                max_count: 2,
                max_total_bytes: 2,
                max_age: Duration::from_secs(60),
            },
            temp.path(),
            "equal timestamp fixture",
        )?;

        assert!(!temp.path().join("a").exists());
        assert!(temp.path().join("b").exists());
        assert!(temp.path().join("c").exists());
        Ok(())
    }

    #[test]
    fn update_logs_have_hard_count_and_total_byte_retention() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let current = temp.path().join("codex-update.log");
        fs::File::create(&current)?.set_len(UPDATE_LOG_ROTATE_BYTES)?;
        for index in 0..4 {
            fs::File::create(temp.path().join(format!("codex-update.log.old-{index}")))?
                .set_len(UPDATE_LOG_ROTATE_BYTES)?;
        }

        rotate_and_retain_update_logs_at(temp.path(), SystemTime::now())?;

        let logs = fs::read_dir(temp.path())?
            .filter_map(std::result::Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.starts_with("codex-update.log"))
            })
            .collect::<Vec<_>>();
        let bytes = logs.iter().try_fold(0_u64, |total, entry| {
            Ok::<_, std::io::Error>(total.saturating_add(entry.metadata()?.len()))
        })?;
        assert!(logs.len() <= UPDATE_LOG_MAX_COUNT);
        assert!(bytes <= UPDATE_LOG_MAX_TOTAL_BYTES);
        assert!(current.exists());
        Ok(())
    }

    #[test]
    fn update_log_max_plus_one_fails_before_rotation_or_creation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let current = temp.path().join("codex-update.log");
        let prior = temp.path().join("codex-update.log.prior");
        fs::File::create(&current)?.set_len(UPDATE_LOG_ROTATE_BYTES)?;
        fs::write(&prior, b"prior")?;

        let error = rotate_and_retain_update_logs_with_limit(temp.path(), SystemTime::now(), 1)
            .expect_err("max + 1 log inventory must fail before rotation");

        assert!(error.to_string().contains("before mutation"));
        assert_eq!(fs::metadata(&current)?.len(), UPDATE_LOG_ROTATE_BYTES);
        assert_eq!(fs::read(&prior)?, b"prior");
        assert_eq!(fs::read_dir(temp.path())?.count(), 2);
        Ok(())
    }

    #[test]
    fn stage_prepared_runtime_copies_main_and_code_mode_host() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let build_dir = temp.path().join("target/release");
        let prepared_dir = temp.path().join("prepared-codex/0.144.1/attempt-a");
        fs::create_dir_all(&build_dir)?;
        let built_binary = build_dir.join("codex");
        fs::write(&built_binary, b"codex")?;
        fs::write(build_dir.join("codex-code-mode-host"), b"host")?;

        let staged = stage_prepared_runtime(&built_binary, &prepared_dir)?;

        assert_eq!(staged, prepared_dir.join("codex"));
        assert_eq!(fs::read(prepared_dir.join("codex"))?, b"codex");
        assert_eq!(
            fs::read(prepared_dir.join("codex-code-mode-host"))?,
            b"host"
        );
        Ok(())
    }

    #[test]
    fn prepared_generation_paths_are_unique_and_immutable() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let first = prepared_generation_dir(temp.path(), "0.144.1", "attempt-a");
        let second = prepared_generation_dir(temp.path(), "0.144.1", "attempt-b");
        assert_ne!(first, second);
        assert_eq!(first.parent(), second.parent());

        let build_dir = temp.path().join("build/release");
        fs::create_dir_all(&build_dir)?;
        let built_binary = build_dir.join("codex");
        fs::write(&built_binary, b"first")?;
        fs::write(build_dir.join("codex-code-mode-host"), b"first-host")?;
        stage_prepared_runtime(&built_binary, &first)?;

        fs::write(&built_binary, b"second")?;
        let error = stage_prepared_runtime(&built_binary, &first)
            .expect_err("an existing generation must never be overwritten");
        assert!(error.to_string().contains("refusing to reuse"));
        assert_eq!(fs::read(first.join("codex"))?, b"first");
        Ok(())
    }

    #[test]
    fn failed_prepare_does_not_change_active_launcher_bytes_or_target() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let active_runtime = write_test_runtime(
            &temp.path().join("prepared-codex/0.144.1/active"),
            "0.144.1",
            true,
        )?;
        let active_runtime_bytes = fs::read(&active_runtime)?;
        let launcher = temp.path().join("patched-codex/codex");
        fs::create_dir_all(launcher.parent().unwrap())?;
        fs::write(
            &launcher,
            format!(
                "#!/bin/sh\nPATCHED_CODEX='{}'\nexec \"$PATCHED_CODEX\" \"$@\"\n",
                active_runtime.display()
            ),
        )?;
        let launcher_bytes = fs::read(&launcher)?;

        let workspace = temp.path().join("source/codex-rs");
        let built_binary = write_test_runtime(&workspace.join("target/release"), "0.144.1", false)?;
        let failed_generation = prepared_generation_dir(temp.path(), "0.144.1", "failed-attempt");
        let error = run_with_build_target_cleanup(&workspace, || {
            stage_and_validate_prepared_runtime(&built_binary, &failed_generation, "0.144.1")
                .map(|_| ())
        })
        .expect_err("stale patch markers must fail preparation");

        assert!(error.to_string().contains("missing hot-swap markers"));
        assert_eq!(fs::read(&launcher)?, launcher_bytes);
        assert_eq!(fs::read(&active_runtime)?, active_runtime_bytes);
        assert!(!failed_generation.exists());
        Ok(())
    }

    #[test]
    fn partial_prepared_generation_is_removed_after_stage_failure() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let active = temp.path().join("prepared-codex/0.144.1/active");
        fs::create_dir_all(&active)?;
        fs::write(active.join("codex"), b"active")?;
        let partial = temp.path().join("prepared-codex/0.144.1/partial");

        let error = with_new_prepared_generation(&partial, |generation| -> Result<()> {
            fs::write(generation.join("codex"), b"partial")?;
            bail!("simulated second-file stage failure")
        })
        .expect_err("the simulated staging operation must fail");

        assert!(error.to_string().contains("second-file stage failure"));
        assert!(!partial.exists());
        assert_eq!(fs::read(active.join("codex"))?, b"active");
        Ok(())
    }

    #[test]
    fn build_target_is_cleaned_after_successful_prepare_operation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let workspace = temp.path().join("codex-rs");
        let target = workspace.join("target");
        fs::create_dir_all(target.join("release"))?;
        fs::write(target.join("release/codex"), b"artifact")?;

        let outcome = run_with_build_target_cleanup(&workspace, || Ok(()))?;

        assert!(!target.exists());
        assert!(outcome.cleanup_warning.is_none());
        Ok(())
    }

    #[test]
    fn successful_prepare_survives_build_target_cleanup_failure() -> Result<()> {
        let outcome = combine_operation_and_cleanup_results(
            Ok("verified-runtime"),
            Err(anyhow::anyhow!("simulated cleanup permission failure")),
        )?;

        assert_eq!(outcome.value, "verified-runtime");
        assert!(outcome
            .cleanup_warning
            .as_ref()
            .is_some_and(|error| error.to_string().contains("cleanup permission failure")));
        Ok(())
    }

    #[test]
    fn non_build_prepare_failure_still_cleans_target() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let workspace = temp.path().join("codex-rs");
        let target = workspace.join("target");
        fs::create_dir_all(target.join("release"))?;
        fs::write(target.join("release/codex"), b"artifact")?;

        let error = run_with_build_target_cleanup(&workspace, || -> Result<()> {
            bail!("simulated staging failure")
        })
        .expect_err("the simulated preparation must fail");

        assert!(error.to_string().contains("simulated staging failure"));
        assert!(!target.exists());
        Ok(())
    }

    #[test]
    fn bounded_build_failure_preserves_and_resumes_matching_target() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let workspace = temp.path().join("codex-rs");
        fs::create_dir_all(&workspace)?;
        let target = workspace.join("target");
        let started_at = automatic_update_test_time();
        let failed_at = started_at + ChronoDuration::hours(2);
        let retry_at = failed_at + ChronoDuration::hours(6);
        let provenance = test_build_target_provenance(
            "0.144.4",
            "upstream-and-patch-a",
            "build-recipe-a",
            started_at,
        );
        let mut preserved = false;

        let error = run_resumable_build_attempt(
            &workspace,
            &provenance,
            &mut preserved,
            || failed_at,
            || -> Result<PathBuf> {
                fs::create_dir_all(target.join("debug/deps"))?;
                fs::write(target.join("debug/deps/resumable.rmeta"), b"cargo-progress")?;
                bail!("simulated bounded build deadline")
            },
            |_| Ok(()),
        )
        .expect_err("the bounded build must fail");

        assert!(preserved);
        assert!(format!("{error:#}").contains("preserved resumable Cargo target"));
        assert_eq!(
            fs::read(target.join("debug/deps/resumable.rmeta"))?,
            b"cargo-progress"
        );
        let mut retry = provenance.clone();
        retry.refreshed_at = retry_at;
        assert_eq!(
            prepare_resumable_build_target_at(&workspace, &retry, retry_at)?,
            BuildTargetPreparation::Resumed
        );
        assert_eq!(
            fs::read(target.join("debug/deps/resumable.rmeta"))?,
            b"cargo-progress"
        );
        Ok(())
    }

    #[test]
    fn different_or_stale_target_provenance_is_replaced_before_build() -> Result<()> {
        let now = automatic_update_test_time();
        for (case, recorded, expected) in [
            (
                "version",
                test_build_target_provenance("0.144.3", "source-a", "recipe-a", now),
                test_build_target_provenance("0.144.4", "source-a", "recipe-a", now),
            ),
            (
                "source",
                test_build_target_provenance("0.144.4", "source-a", "recipe-a", now),
                test_build_target_provenance("0.144.4", "source-b", "recipe-a", now),
            ),
            (
                "recipe",
                test_build_target_provenance("0.144.4", "source-a", "recipe-a", now),
                test_build_target_provenance("0.144.4", "source-a", "recipe-b", now),
            ),
        ] {
            let temp = tempfile::tempdir()?;
            let workspace = temp.path().join(case).join("codex-rs");
            fs::create_dir_all(&workspace)?;
            assert_eq!(
                prepare_resumable_build_target_at(&workspace, &recorded, now)?,
                BuildTargetPreparation::Created
            );
            fs::write(workspace.join("target/old-progress"), case.as_bytes())?;

            assert_eq!(
                prepare_resumable_build_target_at(&workspace, &expected, now)?,
                BuildTargetPreparation::Replaced
            );
            assert!(!workspace.join("target/old-progress").exists());
            assert_eq!(
                load_build_target_provenance(&workspace.join("target"))?,
                Some(expected)
            );
        }

        let temp = tempfile::tempdir()?;
        let workspace = temp.path().join("stale/codex-rs");
        fs::create_dir_all(&workspace)?;
        let recorded = test_build_target_provenance("0.144.4", "source-a", "recipe-a", now);
        prepare_resumable_build_target_at(&workspace, &recorded, now)?;
        fs::write(workspace.join("target/stale-progress"), b"stale")?;
        let stale_at = now
            + ChronoDuration::from_std(SOURCE_TREE_MAX_AGE)
                .expect("source retention age must fit chrono duration");
        let mut expected = recorded;
        expected.refreshed_at = stale_at;

        assert_eq!(
            prepare_resumable_build_target_at(&workspace, &expected, stale_at)?,
            BuildTargetPreparation::Replaced
        );
        assert!(!workspace.join("target/stale-progress").exists());
        Ok(())
    }

    #[test]
    fn patched_source_fingerprint_changes_with_each_provenance_component() {
        let baseline = source_fingerprint_from_parts("0.144.4", b"commit-a", b"patch-a");
        assert_eq!(
            baseline,
            source_fingerprint_from_parts("0.144.4", b"commit-a", b"patch-a")
        );
        assert_ne!(
            baseline,
            source_fingerprint_from_parts("0.144.5", b"commit-a", b"patch-a")
        );
        assert_ne!(
            baseline,
            source_fingerprint_from_parts("0.144.4", b"commit-b", b"patch-a")
        );
        assert_ne!(
            baseline,
            source_fingerprint_from_parts("0.144.4", b"commit-a", b"patch-b")
        );
    }

    #[test]
    fn directory_not_empty_cleanup_is_idempotent_and_strictly_bounded() -> Result<()> {
        let attempts = std::cell::Cell::new(0);
        let pauses = std::cell::Cell::new(0);
        remove_directory_idempotently_with(
            || {
                let attempt = attempts.get() + 1;
                attempts.set(attempt);
                if attempt < BUILD_TARGET_CLEANUP_ATTEMPTS {
                    Err(std::io::Error::from(std::io::ErrorKind::DirectoryNotEmpty))
                } else {
                    Ok(())
                }
            },
            || pauses.set(pauses.get() + 1),
        )?;
        assert_eq!(attempts.get(), BUILD_TARGET_CLEANUP_ATTEMPTS);
        assert_eq!(pauses.get(), BUILD_TARGET_CLEANUP_ATTEMPTS - 1);

        let absent_attempts = std::cell::Cell::new(0);
        remove_directory_idempotently_with(
            || {
                absent_attempts.set(absent_attempts.get() + 1);
                Err(std::io::Error::from(std::io::ErrorKind::NotFound))
            },
            || panic!("absent cleanup must not pause"),
        )?;
        assert_eq!(absent_attempts.get(), 1);

        let persistent_attempts = std::cell::Cell::new(0);
        let error = remove_directory_idempotently_with(
            || {
                persistent_attempts.set(persistent_attempts.get() + 1);
                Err(std::io::Error::from(std::io::ErrorKind::DirectoryNotEmpty))
            },
            || {},
        )
        .expect_err("persistent refill must remain a cleanup failure");
        assert_eq!(error.kind(), std::io::ErrorKind::DirectoryNotEmpty);
        assert_eq!(persistent_attempts.get(), BUILD_TARGET_CLEANUP_ATTEMPTS);
        Ok(())
    }

    #[test]
    fn stale_preparation_cleanup_reclaims_recorded_target_and_generation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let data_dir = temp.path().join("codexswitch");
        let source = data_dir.join("codex-source-stable-0.144.1");
        let target = source.join("codex-rs/target/release");
        let generation = data_dir.join("prepared-codex/0.144.1/attempt-a");
        fs::create_dir_all(&target)?;
        fs::create_dir_all(&generation)?;
        fs::write(target.join("artifact"), b"large build output")?;
        fs::write(generation.join("codex"), b"partial")?;

        let now = automatic_update_test_time();
        let mut state =
            automatic_update_test_state(UpdateStatus::Preparing, now - ChronoDuration::hours(7));
        state.latest_stable_version = Some("0.144.1".to_string());
        state.prepared_version = Some("0.144.1".to_string());
        state.prepared_source_path = Some(source.display().to_string());
        state.prepared_binary_path = Some(generation.join("codex").display().to_string());

        assert!(cleanup_stale_preparation_artifacts_at(
            &mut state, now, &data_dir
        )?);

        assert!(!source.join("codex-rs/target").exists());
        assert!(!generation.exists());
        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(state.failed_prepare_version.as_deref(), Some("0.144.1"));
        assert_eq!(state.prepare_retry_not_before, Some(now));
        assert_eq!(state.prepared_binary_path, None);
        Ok(())
    }

    #[test]
    fn stale_preparation_recovers_fully_validated_generation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let data_dir = temp.path().join("codexswitch");
        let source = data_dir.join("codex-source-stable-0.144.1");
        let target = source.join("codex-rs/target/release");
        let generation = data_dir.join("prepared-codex/0.144.1/attempt-valid");
        fs::create_dir_all(&target)?;
        fs::write(target.join("artifact"), b"large build output")?;
        let runtime = write_test_runtime(&generation, "0.144.1", true)?;

        let now = automatic_update_test_time();
        let mut state =
            automatic_update_test_state(UpdateStatus::Preparing, now - ChronoDuration::hours(7));
        state.latest_stable_version = Some("0.144.1".to_string());
        state.prepared_version = Some("0.144.1".to_string());
        state.prepared_source_path = Some(source.display().to_string());
        state.prepared_binary_path = Some(runtime.display().to_string());

        assert!(cleanup_stale_preparation_artifacts_at(
            &mut state, now, &data_dir
        )?);

        assert_eq!(state.status, UpdateStatus::ReadyToInstall);
        assert!(runtime.exists());
        assert!(!source.join("codex-rs/target").exists());
        assert_eq!(state.prepared_binary_path.as_deref(), runtime.to_str());
        Ok(())
    }

    #[test]
    fn pending_target_cleanup_remains_tracked_until_removed() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let data_dir = temp.path().join("codexswitch");
        let target = data_dir.join("codex-source-stable-0.144.1/codex-rs/target");
        fs::create_dir_all(&target)?;
        fs::write(target.join("artifact"), b"build output")?;
        let mut state =
            automatic_update_test_state(UpdateStatus::Installed, automatic_update_test_time());
        state.cleanup_pending_target_path = Some(target.display().to_string());

        assert!(cleanup_pending_target_at(&mut state, &data_dir)?);
        assert!(!target.exists());
        assert_eq!(state.cleanup_pending_target_path, None);
        Ok(())
    }

    #[test]
    fn prepared_runtime_validation_requires_expected_version() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let runtime = write_test_runtime(temp.path(), "0.144.1", true)?;

        assert!(prepared_runtime_is_valid(&runtime, "0.144.1"));
        assert!(!prepared_runtime_is_valid(&runtime, "0.145.0"));
        Ok(())
    }

    #[test]
    fn direct_prepare_reuses_valid_same_version_generation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let generation = temp.path().join("prepared-codex/0.144.1/attempt-valid");
        let runtime = write_test_runtime(&generation, "0.144.1", true)?;
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Idle, now);
        state.prepared_version = Some("0.144.1".to_string());
        state.prepared_binary_path = Some(runtime.display().to_string());

        assert_eq!(
            reconcile_or_cleanup_existing_prepared_runtime(
                &mut state,
                "0.144.1",
                now,
                temp.path(),
            )?,
            ExistingPreparedRuntimeDisposition::Reused
        );
        assert_eq!(state.status, UpdateStatus::ReadyToInstall);
        assert!(runtime.exists());
        assert!(runtime.with_file_name("codex-code-mode-host").exists());
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn prepared_runtime_validation_rejects_non_executable_helper() -> Result<()> {
        use std::os::unix::fs::PermissionsExt;

        let temp = tempfile::tempdir()?;
        let runtime = write_test_runtime(temp.path(), "0.144.1", true)?;
        let helper = runtime.with_file_name("codex-code-mode-host");
        let mut permissions = fs::metadata(&helper)?.permissions();
        permissions.set_mode(0o644);
        fs::set_permissions(&helper, permissions)?;

        assert!(!prepared_runtime_is_valid(&runtime, "0.144.1"));
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn build_target_cleanup_removes_symlink_without_following_it() -> Result<()> {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir()?;
        let workspace = temp.path().join("codex-rs");
        let outside = temp.path().join("outside-target");
        fs::create_dir_all(&workspace)?;
        fs::create_dir_all(&outside)?;
        fs::write(outside.join("keep"), b"retained")?;
        symlink(&outside, workspace.join("target"))?;

        run_with_build_target_cleanup(&workspace, || Ok(()))?;

        assert!(outside.join("keep").is_file());
        assert!(fs::symlink_metadata(workspace.join("target")).is_err());
        Ok(())
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macho_detection_distinguishes_executables_from_text_fixtures() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let macho = temp.path().join("macho");
        let text = temp.path().join("text");
        fs::write(&macho, [0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0])?;
        fs::write(&text, b"#!/bin/sh\n")?;

        assert!(is_macho_binary(&macho)?);
        assert!(!is_macho_binary(&text)?);
        Ok(())
    }

    #[test]
    fn prepared_runtime_requires_code_mode_host_companion() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let prepared_binary = temp.path().join("codex");
        fs::write(&prepared_binary, b"codex")?;

        assert!(!runtime_has_code_mode_host(&prepared_binary));
        fs::write(temp.path().join("codex-code-mode-host"), b"host")?;
        assert!(runtime_has_code_mode_host(&prepared_binary));
        Ok(())
    }

    #[test]
    fn runtime_match_rejects_same_size_but_different_patch_builds() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let installed = temp.path().join("installed/codex");
        let prepared = temp.path().join("prepared/codex");
        fs::create_dir_all(installed.parent().unwrap())?;
        fs::create_dir_all(prepared.parent().unwrap())?;
        fs::write(&installed, b"old")?;
        fs::write(
            installed.with_file_name("codex-code-mode-host"),
            b"old-host",
        )?;
        fs::write(&prepared, b"new")?;
        fs::write(prepared.with_file_name("codex-code-mode-host"), b"new-host")?;

        assert!(!runtime_matches_prepared_runtime(&installed, &prepared));
        fs::copy(&prepared, &installed)?;
        fs::copy(
            prepared.with_file_name("codex-code-mode-host"),
            installed.with_file_name("codex-code-mode-host"),
        )?;
        assert!(runtime_matches_prepared_runtime(&installed, &prepared));
        Ok(())
    }

    #[test]
    fn app_server_shutdown_patch_reserves_sighup_for_auth_reload() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let app_server = temp.path().join("lib.rs");
        fs::write(
            &app_server,
            r#"
#[derive(Clone, Copy)]
enum ShutdownSignal {
    Forceable,
    #[cfg(unix)]
    GracefulOnly,
}

async fn shutdown_signal() -> IoResult<ShutdownSignal> {
    #[cfg(unix)]
    {
        let mut term = signal(SignalKind::terminate())?;
        let mut hangup = signal(SignalKind::hangup())?;
        tokio::select! {
            ctrl_c_result = tokio::signal::ctrl_c() => ctrl_c_result.map(|_| ShutdownSignal::Forceable),
            _ = term.recv() => Ok(ShutdownSignal::Forceable),
            _ = hangup.recv() => Ok(ShutdownSignal::GracefulOnly),
        }
    }
}
"#,
        )?;

        patch_app_server_shutdown_signal_source(&app_server)?;

        let patched = fs::read_to_string(app_server)?;
        assert!(patched.contains("CODEXSWITCH_SIGHUP_RELOAD_ONLY"));
        assert!(!patched.contains("SignalKind::hangup"));
        assert!(!patched.contains("GracefulOnly"));
        Ok(())
    }

    #[test]
    fn foreground_tui_sighup_handler_is_removed() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let tui = temp.path().join("lib.rs");
        fs::write(
            &tui,
            r#"pub async fn main() {
    #[cfg(unix)]
    {
        let _ = std::fs::write("sighup-verified-tui", "tui\n");
        tokio::spawn(async move {
            tracing::debug!(
                "SIGHUP: auth reloaded from disk (foreground session ignores signal; app-server reloads auth)"
            );
        });
    }

    // Initialize high-fidelity session event logging if enabled.
}
"#,
        )?;

        remove_foreground_tui_sighup_handler(&tui)?;

        let patched = fs::read_to_string(tui)?;
        assert!(!patched.contains("sighup-verified-tui"));
        assert!(!patched.contains("foreground session ignores signal"));
        assert!(patched.contains("Initialize high-fidelity session event logging"));
        Ok(())
    }

    #[test]
    fn app_server_frontend_write_ack_patch_counts_only_successfully_enqueued_writers() -> Result<()>
    {
        let temp = tempfile::tempdir()?;
        let outgoing = temp.path().join("outgoing_message.rs");
        let transport = temp.path().join("transport.rs");
        fs::write(
            &outgoing,
            r#"enum OutgoingEnvelope {
    Broadcast {
        message: OutgoingMessage,
    },
}
"#,
        )?;
        fs::write(
            &transport,
            r#"async fn route(envelope: OutgoingEnvelope) {
    match envelope {
        OutgoingEnvelope::Broadcast { message } => {
            send(message).await;
        }
    }
}
"#,
        )?;

        patch_app_server_frontend_write_ack_source(&outgoing, &transport)?;

        let outgoing = fs::read_to_string(outgoing)?;
        let transport = fs::read_to_string(transport)?;
        assert!(outgoing.contains("BroadcastWithWriteAck"));
        assert!(outgoing
            .contains("write_complete_tx: oneshot::Sender<(usize, usize, usize, usize, usize)>"));
        assert!(transport.contains("connection_state.initialized.load"));
        assert!(transport.contains("initialized_frontend_count"));
        assert!(transport.contains("skipped_frontend_count"));
        assert!(transport
            .contains("initialized_frontend_count.saturating_sub(target_connections.len())"));
        assert!(transport.contains("eligible_frontend_count"));
        assert!(transport.contains("rejected_frontend_count"));
        assert!(transport.contains("let mut rejected_frontend_count = 0usize"));
        assert!(transport.contains("Some(connection_write_tx)"));
        assert!(transport.contains("if !send_message_to_connection("));
        assert!(transport.contains("eligible_frontend_count += 1"));
        assert!(transport.contains("rejected_frontend_count += 1"));
        assert!(transport.contains("completed_writes"));
        assert!(transport.contains("matches!(result, Ok(Ok(())))"));
        Ok(())
    }

    #[test]
    fn app_server_notification_template_supports_legacy_and_timestamped_transports() -> Result<()> {
        let desktop =
            "crate::outgoing_message::OutgoingMessage::AppServerNotification(ServerNotification::AccountUpdated(value))";
        let local =
            "OutgoingMessage::AppServerNotification(ServerNotification::AccountUpdated(value))";

        assert_eq!(
            adapt_account_updated_notification_template(desktop, false)?,
            desktop
        );
        let timestamped_desktop =
            adapt_account_updated_notification_template(desktop, true)?;
        assert!(timestamped_desktop.contains(
            "crate::outgoing_message::timestamped_server_notification("
        ));
        assert!(!timestamped_desktop.contains("AppServerNotification("));

        let timestamped_local = adapt_account_updated_notification_template(local, true)?;
        assert!(timestamped_local.contains(
            "crate::outgoing_message::timestamped_server_notification("
        ));
        assert!(!timestamped_local.contains("AppServerNotification("));
        Ok(())
    }

    #[test]
    fn app_server_reload_templates_use_the_timestamped_helper_when_available() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let app_server = temp.path().join("lib.rs");
        let in_process = temp.path().join("in_process.rs");
        fs::write(
            &app_server,
            r#"async fn run() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
    });
}
"#,
        )?;
        fs::write(
            &in_process,
            r#"async fn run(args: InProcessStartArgs) {
    let auth_manager =
            AuthManager::shared_from_config(args.config.as_ref(), args.enable_codex_api_key_env)
                .await;
}
"#,
        )?;

        patch_app_server_reload_template(&app_server, &in_process, true)?;

        for path in [&app_server, &in_process] {
            let patched = fs::read_to_string(path)?;
            assert!(patched.contains(
                "crate::outgoing_message::timestamped_server_notification("
            ));
            assert!(!patched.contains("OutgoingMessage::AppServerNotification("));
        }
        Ok(())
    }

    #[test]
    fn timestamped_notification_helper_is_promoted_idempotently() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let outgoing = temp.path().join("outgoing_message.rs");
        fs::write(
            &outgoing,
            r#"use codex_app_server_protocol::ServerNotificationEnvelope;

fn timestamped_server_notification(notification: ServerNotification) -> OutgoingMessage {
    OutgoingMessage::AppServerNotification(ServerNotificationEnvelope {
        notification,
        emitted_at_ms: Some(1),
    })
}
"#,
        )?;

        assert!(patch_timestamped_server_notification_visibility(&outgoing)?);
        assert!(patch_timestamped_server_notification_visibility(&outgoing)?);
        let patched = fs::read_to_string(outgoing)?;
        assert_eq!(
            patched
                .matches("pub(crate) fn timestamped_server_notification")
                .count(),
            1
        );
        Ok(())
    }

    #[test]
    fn unknown_notification_envelope_shape_fails_before_build() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let outgoing = temp.path().join("outgoing_message.rs");
        fs::write(
            &outgoing,
            "use codex_app_server_protocol::ServerNotificationEnvelope;\n",
        )?;

        let error = patch_timestamped_server_notification_visibility(&outgoing)
            .expect_err("unknown envelope shape must fail closed");
        assert!(error
            .to_string()
            .contains("notification envelope shape changed"));
        Ok(())
    }

    #[test]
    fn stable_source_tags_refuse_alpha_versions() {
        assert_eq!(stable_source_tag("0.128.0").unwrap(), "rust-v0.128.0");
        assert!(stable_source_tag("0.129.0-alpha.1").is_err());
    }

    #[test]
    fn stable_version_filter_rejects_prereleases() {
        assert!(version_is_stable("0.128.0"));
        assert!(!version_is_stable("0.128.0-alpha.15"));
        assert!(!version_is_stable("latest"));
    }

    #[test]
    fn same_version_observation_preserves_failure_and_rebuilds_only_stale_contract() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let current = write_test_runtime(&temp.path().join("current"), "0.144.1", true)?;
        let stale = write_test_runtime(&temp.path().join("stale"), "0.144.1", false)?;
        let now = automatic_update_test_time();

        let mut current_state = automatic_update_test_state(UpdateStatus::Failed, now);
        current_state.failed_prepare_version = Some("0.144.1".to_string());
        current_state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));
        current_state.error = Some("stale failure".to_string());
        let current_installed = installed_codex_version_from_path(&current);
        let mut current_builds = 0;
        if !reconcile_requested_version_as_installed(
            &mut current_state,
            "0.144.1",
            current_installed,
            now,
        ) {
            current_builds += 1;
        }
        assert_eq!(current_builds, 0);
        assert_eq!(current_state.status, UpdateStatus::Failed);
        assert_eq!(
            current_state.failed_prepare_version.as_deref(),
            Some("0.144.1")
        );
        assert_eq!(
            current_state.prepare_retry_not_before,
            Some(now + ChronoDuration::hours(6))
        );
        assert_eq!(current_state.error.as_deref(), Some("stale failure"));

        let stale_installed = installed_codex_version_from_path(&stale);
        assert_eq!(stale_installed, None);
        let mut stale_state = automatic_update_test_state(UpdateStatus::Idle, now);
        stale_state.latest_stable_version = Some("0.144.1".to_string());
        stale_state.installed_version = Some("0.144.1".to_string());
        assert!(!reconcile_requested_version_as_installed(
            &mut stale_state,
            "0.144.1",
            stale_installed,
            now,
        ));
        assert_eq!(
            automatic_update_decision(
                &stale_state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::PrepareStableVersion("0.144.1".to_string())
        );

        stale_state.status = UpdateStatus::Failed;
        stale_state.failed_prepare_version = Some("0.144.1".to_string());
        stale_state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));
        stale_state.updated_at = now;
        assert_eq!(
            automatic_update_decision(
                &stale_state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );
        Ok(())
    }

    #[test]
    fn ready_status_names_install_command_and_version() {
        let state = CodexUpdateState {
            status: UpdateStatus::ReadyToInstall,
            last_checked_at: None,
            latest_stable_version: Some("0.128.0".to_string()),
            installed_version: Some("0.126.0".to_string()),
            installed_artifact_manifest_sha256: None,
            prepared_version: Some("0.128.0".to_string()),
            prepared_source_path: None,
            prepared_binary_path: None,
            prepared_artifact_manifest_sha256: None,
            failed_prepare_version: None,
            prepare_retry_not_before: None,
            failed_install_version: None,
            install_retry_not_before: None,
            cleanup_pending_target_path: None,
            unresolved_failure: None,
            install_transaction: None,
            error: Some("build target cleanup pending".to_string()),
            updated_at: Utc::now(),
        };
        let report = report_from_state(state);
        assert!(report.summary.contains("0.128.0"));
        assert!(report.summary.contains("build target cleanup pending"));
        assert_eq!(
            report.install_command.as_deref(),
            Some("codexswitch-cli install-prepared-codex")
        );
    }

    #[test]
    fn macos_idle_status_never_recommends_a_local_source_build() {
        let state = automatic_update_test_state(UpdateStatus::Idle, Utc::now());
        let summary = summary_for_state_on_platform(&state, None, HostPlatform::MacOs);
        assert!(summary.contains("attested remote macOS runtime artifact"));
        assert!(!summary.contains("--prepare"));
    }

    #[test]
    fn update_state_failure_fields_are_backward_compatible_and_persisted() -> Result<()> {
        let legacy = serde_json::json!({
            "status": "idle",
            "lastCheckedAt": null,
            "latestStableVersion": "0.144.1",
            "installedVersion": "0.143.0",
            "preparedVersion": null,
            "preparedSourcePath": null,
            "preparedBinaryPath": null,
            "error": null,
            "updatedAt": "2026-07-12T12:00:00Z"
        });
        let mut state: CodexUpdateState = serde_json::from_value(legacy)?;
        assert_eq!(state.failed_prepare_version, None);
        assert_eq!(state.prepare_retry_not_before, None);
        assert_eq!(state.failed_install_version, None);
        assert_eq!(state.install_retry_not_before, None);
        assert_eq!(state.cleanup_pending_target_path, None);

        state.failed_prepare_version = Some("0.144.1".to_string());
        state.prepare_retry_not_before = Some(automatic_update_test_time());
        state.failed_install_version = Some("0.144.1".to_string());
        state.install_retry_not_before = Some(automatic_update_test_time());
        state.cleanup_pending_target_path =
            Some("/tmp/codex-source-stable-0.144.1/codex-rs/target".to_string());
        state.status = UpdateStatus::Failed;
        state.error = Some("preparation failed".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Preparation,
            automatic_update_test_time(),
            Some("0.144.1".to_string()),
            None,
        );
        let persisted = serde_json::to_value(state)?;
        assert_eq!(persisted["failedPrepareVersion"], "0.144.1");
        assert_eq!(persisted["prepareRetryNotBefore"], "2026-07-12T12:00:00Z");
        assert_eq!(persisted["failedInstallVersion"], "0.144.1");
        assert_eq!(persisted["installRetryNotBefore"], "2026-07-12T12:00:00Z");
        assert_eq!(
            persisted["cleanupPendingTargetPath"],
            "/tmp/codex-source-stable-0.144.1/codex-rs/target"
        );
        assert_eq!(
            persisted["unresolvedFailure"]["failedPrepareVersion"],
            "0.144.1"
        );
        assert_eq!(
            persisted["unresolvedFailure"]["prepareRetryNotBefore"],
            "2026-07-12T12:00:00Z"
        );
        Ok(())
    }

    #[test]
    fn update_state_commit_atomically_replaces_existing_json() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let path = temp.path().join("codex-cli-update.json");
        fs::write(&path, b"old state")?;
        let state = automatic_update_test_state(UpdateStatus::Failed, automatic_update_test_time());

        save_state_at(&path, &state)?;

        let persisted: CodexUpdateState = serde_json::from_slice(&fs::read(&path)?)?;
        assert_eq!(persisted.status, UpdateStatus::Failed);
        assert_eq!(
            fs::read_dir(temp.path())?
                .filter_map(Result::ok)
                .filter(|entry| entry.file_name().to_string_lossy().contains(".tmp-"))
                .count(),
            0
        );
        Ok(())
    }

    #[cfg(unix)]
    #[test]
    fn state_reads_are_bounded_no_follow_and_absent_default_is_pure() -> Result<()> {
        use std::os::unix::fs::symlink;

        let temp = tempfile::tempdir()?;
        let absent = temp.path().join("absent.json");
        let state = load_state_at(&absent)?;
        assert_eq!(state.installed_version, None);
        assert_eq!(state.status, UpdateStatus::Idle);

        let oversized = temp.path().join("oversized.json");
        fs::File::create(&oversized)?.set_len(UPDATE_STATE_MAX_BYTES + 1)?;
        assert!(load_state_at(&oversized)
            .expect_err("oversized state must fail")
            .to_string()
            .contains("byte limit"));

        let target = temp.path().join("target.json");
        save_state_at(
            &target,
            &automatic_update_test_state(UpdateStatus::Idle, automatic_update_test_time()),
        )?;
        let linked = temp.path().join("linked.json");
        symlink(&target, &linked)?;
        assert!(load_state_at(&linked)
            .expect_err("symlink state must fail")
            .to_string()
            .contains("non-symlink"));
        Ok(())
    }

    #[test]
    fn chunked_registry_metadata_is_bounded_before_json_decode() -> Result<()> {
        struct ChunkedReader {
            bytes: Vec<u8>,
            offset: usize,
            chunk: usize,
        }

        impl Read for ChunkedReader {
            fn read(&mut self, output: &mut [u8]) -> std::io::Result<usize> {
                if self.offset == self.bytes.len() {
                    return Ok(0);
                }
                let count = self
                    .chunk
                    .min(output.len())
                    .min(self.bytes.len() - self.offset);
                output[..count].copy_from_slice(&self.bytes[self.offset..self.offset + count]);
                self.offset += count;
                Ok(count)
            }
        }

        assert_eq!(
            decode_latest_stable_metadata(ChunkedReader {
                bytes: br#"{"version":"0.145.0"}"#.to_vec(),
                offset: 0,
                chunk: 2,
            })?,
            "0.145.0"
        );
        let error = decode_latest_stable_metadata(ChunkedReader {
            bytes: vec![b' '; REGISTRY_METADATA_MAX_BYTES as usize + 1],
            offset: 0,
            chunk: 7,
        })
        .expect_err("chunked oversized metadata must fail before decoding");
        assert!(error.to_string().contains("byte limit"));
        Ok(())
    }

    #[test]
    fn checking_crash_replay_restores_serialized_preparation_failure() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let state_path = temp.path().join("codex-cli-update.json");
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.installed_version = Some("0.145.0".to_string());
        state.prepared_version = Some("0.145.0".to_string());
        state.failed_prepare_version = Some("0.145.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));
        state.error = Some("source preparation failed".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Preparation,
            now,
            Some("0.145.0".to_string()),
            None,
        );
        state.status = UpdateStatus::Checking;
        state.error = None;
        save_state_at(&state_path, &state)?;
        let reconciliations = std::cell::Cell::new(0);

        let report = status_report_at(
            &state_path,
            || Some("0.145.0".to_string()),
            |state| {
                reconciliations.set(reconciliations.get() + 1);
                mark_version_installed(state, "0.145.0", now);
                true
            },
        )?;

        assert_eq!(reconciliations.get(), 0);
        assert_eq!(report.status, UpdateStatus::Failed);
        assert_eq!(report.failed_prepare_version.as_deref(), Some("0.145.0"));
        assert_eq!(
            report.prepare_retry_not_before,
            Some(now + ChronoDuration::hours(6))
        );
        assert_eq!(report.error.as_deref(), Some("source preparation failed"));
        let persisted = load_state_at(&state_path)?;
        assert_eq!(persisted.status, UpdateStatus::Checking);
        assert!(persisted.unresolved_failure.is_some());
        Ok(())
    }

    #[test]
    fn status_reader_observes_without_creating_or_acquiring_updater_lock() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let state_path = temp.path().join("codex-cli-update.json");
        let lock_path = temp.path().join("codex-update.lock");
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.failed_prepare_version = Some("0.145.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));
        state.error = Some("preparation failed before checking".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Preparation,
            now,
            Some("0.145.0".to_string()),
            None,
        );
        state.status = UpdateStatus::Checking;
        save_state_at(&state_path, &state)?;
        let installed_observations = std::cell::Cell::new(0);
        let reconciliations = std::cell::Cell::new(0);

        let report = status_report_at(
            &state_path,
            || {
                installed_observations.set(installed_observations.get() + 1);
                Some("0.145.0".to_string())
            },
            |_| {
                reconciliations.set(reconciliations.get() + 1);
                true
            },
        )?;

        assert_eq!(report.status, UpdateStatus::Failed);
        assert_eq!(installed_observations.get(), 1);
        assert_eq!(reconciliations.get(), 0);
        assert_eq!(load_state_at(&state_path)?.status, UpdateStatus::Checking);
        assert!(!lock_path.exists());
        Ok(())
    }

    #[test]
    fn status_reader_does_not_create_missing_state_or_parent() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let data_dir = temp.path().join("missing-data-dir");
        let state_path = data_dir.join("codex-cli-update.json");

        let report = status_report_at(&state_path, || None, |_| false)?;

        assert_eq!(report.status, UpdateStatus::Idle);
        assert!(!data_dir.exists());
        Ok(())
    }

    #[test]
    fn checking_reconciliation_uses_durable_failure_not_transient_status() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.failed_prepare_version = Some("0.145.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));
        state.error = Some("preparation failed".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Preparation,
            now,
            Some("0.145.0".to_string()),
            None,
        );
        state.status = UpdateStatus::Checking;
        state.error = None;

        let should_prepare = apply_successful_metadata_check(
            &mut state,
            "0.145.0",
            Some("0.145.0".to_string()),
            false,
            false,
            false,
            UpdateStatus::Checking,
            now,
        );

        assert!(!should_prepare);
        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(state.failed_prepare_version.as_deref(), Some("0.145.0"));
        assert_eq!(state.error.as_deref(), Some("preparation failed"));
    }

    #[test]
    fn metadata_failure_does_not_replace_prior_typed_failure() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.error = Some("activation acknowledgement failed".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Activation,
            now,
            Some("0.145.0".to_string()),
            None,
        );
        state.status = UpdateStatus::Checking;
        state.error = None;

        apply_metadata_failure(
            &mut state,
            "registry transport timed out".to_string(),
            now + ChronoDuration::minutes(1),
        );

        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(
            state.error.as_deref(),
            Some("activation acknowledgement failed")
        );
        assert_eq!(
            state
                .unresolved_failure
                .as_ref()
                .map(|failure| failure.kind),
            Some(UpdateFailureKind::Activation)
        );
    }

    #[test]
    fn successful_metadata_check_resolves_only_a_metadata_failure() {
        let now = automatic_update_test_time();
        let mut metadata = automatic_update_test_state(UpdateStatus::Failed, now);
        metadata.error = Some("registry transport failed".to_string());
        record_unresolved_failure(&mut metadata, UpdateFailureKind::Metadata, now, None, None);

        apply_successful_metadata_check(
            &mut metadata,
            "0.146.0",
            Some("0.145.0".to_string()),
            false,
            false,
            false,
            UpdateStatus::Failed,
            now + ChronoDuration::minutes(1),
        );

        assert_eq!(metadata.status, UpdateStatus::Idle);
        assert!(metadata.unresolved_failure.is_none());
        assert_eq!(metadata.error, None);

        let mut activation = automatic_update_test_state(UpdateStatus::Failed, now);
        activation.error = Some("activation acknowledgement failed".to_string());
        record_unresolved_failure(
            &mut activation,
            UpdateFailureKind::Activation,
            now,
            Some("0.145.0".to_string()),
            None,
        );

        apply_successful_metadata_check(
            &mut activation,
            "0.146.0",
            Some("0.145.0".to_string()),
            false,
            false,
            false,
            UpdateStatus::Failed,
            now + ChronoDuration::minutes(1),
        );

        assert_eq!(activation.status, UpdateStatus::Failed);
        assert_eq!(
            activation.error.as_deref(),
            Some("activation acknowledgement failed")
        );
        assert_eq!(
            activation
                .unresolved_failure
                .as_ref()
                .map(|failure| failure.kind),
            Some(UpdateFailureKind::Activation)
        );
    }

    #[test]
    fn blocked_install_replay_is_typed_without_replacing_older_failure() {
        let now = automatic_update_test_time();
        let mut interrupted = automatic_update_test_state(UpdateStatus::Installing, now);
        interrupted.prepared_version = Some("0.145.0".to_string());
        interrupted.install_transaction = Some(InstallTransactionState {
            id: "install-transaction-1".to_string(),
            version: "0.145.0".to_string(),
            phase: InstallTransactionStatePhase::Interruptible,
        });

        record_interrupted_install_block(
            &mut interrupted,
            "runtime became active during recovery".to_string(),
        );

        let failure = interrupted
            .unresolved_failure
            .as_ref()
            .expect("blocked replay must persist a typed failure");
        assert_eq!(failure.kind, UpdateFailureKind::Installation);
        assert_eq!(failure.version.as_deref(), Some("0.145.0"));
        assert_eq!(
            failure.transaction_id.as_deref(),
            Some("install-transaction-1")
        );
        assert_eq!(
            interrupted.failed_install_version.as_deref(),
            Some("0.145.0")
        );

        let mut prior = automatic_update_test_state(UpdateStatus::Failed, now);
        prior.error = Some("activation acknowledgement failed".to_string());
        record_unresolved_failure(
            &mut prior,
            UpdateFailureKind::Activation,
            now,
            Some("0.145.0".to_string()),
            None,
        );
        let expected = prior.unresolved_failure.clone();

        record_interrupted_install_block(
            &mut prior,
            "later install replay was blocked".to_string(),
        );

        assert_eq!(prior.unresolved_failure, expected);
        assert_eq!(
            prior.error.as_deref(),
            Some("activation acknowledgement failed")
        );
    }

    #[test]
    fn preparation_failure_does_not_replace_prior_activation_failure() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.error = Some("runtime activation acknowledgement failed".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Activation,
            now,
            Some("0.145.0".to_string()),
            None,
        );
        state.status = UpdateStatus::Failed;
        state.error = Some("source preparation failed".to_string());
        state.failed_prepare_version = Some("0.146.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));

        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Preparation,
            now + ChronoDuration::minutes(1),
            Some("0.146.0".to_string()),
            None,
        );

        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(
            state.error.as_deref(),
            Some("runtime activation acknowledgement failed")
        );
        assert_eq!(state.failed_prepare_version, None);
        assert_eq!(
            state
                .unresolved_failure
                .as_ref()
                .map(|failure| failure.kind),
            Some(UpdateFailureKind::Activation)
        );
    }

    #[test]
    fn install_success_clears_only_matching_install_transaction_failure() {
        let now = automatic_update_test_time();
        let mut matching = automatic_update_test_state(UpdateStatus::Failed, now);
        matching.error = Some("install interrupted".to_string());
        matching.install_transaction = Some(InstallTransactionState {
            id: "tx-1".to_string(),
            version: "0.145.0".to_string(),
            phase: InstallTransactionStatePhase::Interruptible,
        });
        record_unresolved_failure(
            &mut matching,
            UpdateFailureKind::Installation,
            now,
            Some("0.145.0".to_string()),
            Some("tx-1".to_string()),
        );
        mark_version_installed_for_transaction(&mut matching, "0.145.0", "tx-1", now);
        assert_eq!(matching.status, UpdateStatus::Installed);
        assert!(matching.unresolved_failure.is_none());

        let mut activation = automatic_update_test_state(UpdateStatus::Failed, now);
        activation.error = Some("activation failed".to_string());
        activation.install_transaction = Some(InstallTransactionState {
            id: "tx-1".to_string(),
            version: "0.145.0".to_string(),
            phase: InstallTransactionStatePhase::Interruptible,
        });
        record_unresolved_failure(
            &mut activation,
            UpdateFailureKind::Activation,
            now,
            Some("0.145.0".to_string()),
            None,
        );
        mark_version_installed_for_transaction(&mut activation, "0.145.0", "tx-1", now);
        assert_eq!(activation.status, UpdateStatus::Failed);
        assert_eq!(activation.error.as_deref(), Some("activation failed"));
    }

    #[test]
    fn metadata_check_cannot_reenable_failed_same_version() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.failed_prepare_version = Some("0.145.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));
        state.error = Some("build failed".to_string());

        let should_prepare = apply_successful_metadata_check(
            &mut state,
            "0.145.0",
            Some("0.144.1".to_string()),
            false,
            false,
            false,
            UpdateStatus::Failed,
            now,
        );

        assert!(!should_prepare);
        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(state.failed_prepare_version.as_deref(), Some("0.145.0"));
        assert_eq!(
            state.prepare_retry_not_before,
            Some(now + ChronoDuration::hours(6))
        );
        assert_eq!(state.error.as_deref(), Some("build failed"));
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );
        let mut summary_state = state.clone();
        summary_state.prepare_retry_not_before = Some(Utc::now() + ChronoDuration::hours(6));
        assert!(summary_for_state(&summary_state, None).contains("retry deferred until"));
    }

    #[test]
    fn same_version_reconciliation_preserves_generic_failed_state_and_metadata() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.failed_prepare_version = Some("0.143.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(4));
        state.failed_install_version = Some("0.142.0".to_string());
        state.install_retry_not_before = Some(now + ChronoDuration::hours(5));
        state.error = Some("prior updater failed before activation".to_string());

        assert!(reconcile_requested_version_as_installed(
            &mut state,
            "0.145.0",
            Some("0.145.0".to_string()),
            now,
        ));
        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(state.failed_prepare_version.as_deref(), Some("0.143.0"));
        assert_eq!(
            state.prepare_retry_not_before,
            Some(now + ChronoDuration::hours(4))
        );
        assert_eq!(state.failed_install_version.as_deref(), Some("0.142.0"));
        assert_eq!(
            state.install_retry_not_before,
            Some(now + ChronoDuration::hours(5))
        );
        assert_eq!(
            state.error.as_deref(),
            Some("prior updater failed before activation")
        );

        let should_prepare = apply_successful_metadata_check(
            &mut state,
            "0.145.0",
            Some("0.145.0".to_string()),
            false,
            true,
            true,
            UpdateStatus::Failed,
            now,
        );
        assert!(!should_prepare);
        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(state.failed_prepare_version.as_deref(), Some("0.143.0"));
        assert_eq!(
            state.prepare_retry_not_before,
            Some(now + ChronoDuration::hours(4))
        );
        assert_eq!(state.failed_install_version.as_deref(), Some("0.142.0"));
        assert_eq!(
            state.install_retry_not_before,
            Some(now + ChronoDuration::hours(5))
        );
        assert_eq!(
            state.error.as_deref(),
            Some("prior updater failed before activation")
        );
    }

    #[test]
    fn same_version_metadata_check_preserves_installed_artifact_identity() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Installed, now);
        state.latest_stable_version = Some("0.144.1".to_string());
        state.installed_artifact_manifest_sha256 = Some("manifest-sha256".to_string());

        let should_prepare = apply_successful_metadata_check(
            &mut state,
            "0.144.1",
            Some("0.144.1".to_string()),
            false,
            false,
            false,
            UpdateStatus::Installed,
            now + ChronoDuration::minutes(15),
        );

        assert!(!should_prepare);
        assert_eq!(state.status, UpdateStatus::Installed);
        assert_eq!(
            state.installed_artifact_manifest_sha256.as_deref(),
            Some("manifest-sha256")
        );
    }

    #[test]
    fn changed_installed_version_observation_clears_artifact_identity() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Installed, now);
        state.installed_artifact_manifest_sha256 = Some("stale-manifest-sha256".to_string());

        observe_installed_version(&mut state, Some("0.145.0".to_string()));

        assert_eq!(state.installed_version.as_deref(), Some("0.145.0"));
        assert!(state.installed_artifact_manifest_sha256.is_none());
    }

    #[test]
    fn same_version_reconciliation_preserves_failed_activation_truth() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.latest_stable_version = Some("0.145.0".to_string());
        state.prepared_version = Some("0.145.0".to_string());
        state.failed_install_version = Some("0.145.0".to_string());
        state.install_retry_not_before = Some(now + ChronoDuration::hours(6));
        state.error = Some("runtime activation failed".to_string());

        let reconciled = reconcile_requested_version_as_installed(
            &mut state,
            "0.145.0",
            Some("0.145.0".to_string()),
            now,
        );

        assert!(reconciled);
        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(state.failed_install_version.as_deref(), Some("0.145.0"));
        assert_eq!(state.error.as_deref(), Some("runtime activation failed"));

        let should_prepare = apply_successful_metadata_check(
            &mut state,
            "0.145.0",
            Some("0.145.0".to_string()),
            true,
            true,
            true,
            UpdateStatus::Failed,
            now,
        );
        assert!(!should_prepare);
        assert_eq!(state.status, UpdateStatus::Failed);
        assert_eq!(state.failed_install_version.as_deref(), Some("0.145.0"));
        assert_eq!(state.error.as_deref(), Some("runtime activation failed"));
    }

    #[test]
    fn same_version_reconciliation_preserves_installing_truth() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Installing, now);
        state.prepared_version = Some("0.145.0".to_string());

        assert!(reconcile_requested_version_as_installed(
            &mut state,
            "0.145.0",
            Some("0.145.0".to_string()),
            now,
        ));
        assert_eq!(state.status, UpdateStatus::Installing);
        assert_eq!(state.prepared_version.as_deref(), Some("0.145.0"));
    }

    #[test]
    fn registry_rollback_does_not_clear_newer_version_cooldown() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.failed_prepare_version = Some("0.145.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));

        apply_successful_metadata_check(
            &mut state,
            "0.144.1",
            Some("0.144.1".to_string()),
            false,
            false,
            false,
            UpdateStatus::Failed,
            now,
        );

        assert_eq!(state.failed_prepare_version.as_deref(), Some("0.145.0"));
        assert_eq!(
            state.prepare_retry_not_before,
            Some(now + ChronoDuration::hours(6))
        );
    }

    #[test]
    fn failed_install_is_never_retried_automatically() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let runtime = write_test_runtime(temp.path(), "0.145.0", true)?;
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.prepared_version = Some("0.145.0".to_string());
        state.prepared_binary_path = Some(runtime.display().to_string());
        state.failed_install_version = Some("0.145.0".to_string());
        state.install_retry_not_before = Some(now + ChronoDuration::hours(6));

        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );

        state.install_retry_not_before = Some(now);
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );
        Ok(())
    }

    #[test]
    fn newer_stable_version_bypasses_older_prepare_failure() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);
        state.failed_prepare_version = Some("0.145.0".to_string());
        state.prepare_retry_not_before = Some(now + ChronoDuration::hours(6));
        state.error = Some("0.145.0 source preparation failed".to_string());
        record_unresolved_failure(
            &mut state,
            UpdateFailureKind::Preparation,
            now,
            Some("0.145.0".to_string()),
            None,
        );

        apply_successful_metadata_check(
            &mut state,
            "0.146.0",
            Some("0.144.1".to_string()),
            false,
            false,
            false,
            UpdateStatus::Failed,
            now,
        );

        assert_eq!(state.failed_prepare_version, None);
        assert_eq!(state.prepare_retry_not_before, None);
        assert_eq!(state.unresolved_failure, None);
        assert_eq!(state.status, UpdateStatus::Idle);
        assert_eq!(state.error, None);
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::PrepareStableVersion("0.146.0".to_string())
        );
    }

    #[test]
    fn automatic_update_checks_idle_state_every_fifteen_minutes() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Idle, now);
        state.latest_stable_version = state.installed_version.clone();

        state.last_checked_at = Some(now - ChronoDuration::seconds(899));
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );

        state.last_checked_at = Some(now - ChronoDuration::minutes(15));
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::CheckStableChannel
        );
    }

    #[test]
    fn automatic_update_backs_off_failures_for_six_hours() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Failed, now);

        state.updated_at = now - ChronoDuration::seconds(21_599);
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );

        state.updated_at = now - ChronoDuration::hours(6);
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::CheckStableChannel
        );
    }

    #[test]
    fn linux_automatic_ready_to_install_stays_staged_while_runtime_is_active() {
        let now = automatic_update_test_time();
        let state = automatic_update_test_state(UpdateStatus::ReadyToInstall, now);
        let activity = ManagedRuntimeActivity {
            systemd_unit: RuntimeActivityObservation::Active,
            app_server_daemon: RuntimeActivityObservation::Inactive,
        };
        let decision = automatic_update_decision(&state, now, linux_automatic_context(0));

        assert!(managed_runtime_block_reason(&activity).is_some());
        assert_eq!(decision, AutomaticUpdateDecision::None);
        assert!(background_update_args(&decision).is_empty());
    }

    #[test]
    fn periodic_entrypoint_does_not_duplicate_a_ready_generation() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let state_path = temp.path().join("codex-cli-update.json");
        let generation = temp
            .path()
            .join("prepared-codex/0.144.3/one-provenance-generation");
        let runtime = write_test_runtime(&generation, "0.144.3", true)?;
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::ReadyToInstall, now);
        state.latest_stable_version = Some("0.144.3".to_string());
        state.installed_version = Some("0.144.1".to_string());
        state.prepared_version = Some("0.144.3".to_string());
        state.prepared_binary_path = Some(runtime.display().to_string());
        save_state_at(&state_path, &state)?;

        let metadata_calls = std::cell::Cell::new(0);
        let preparation_calls = std::cell::Cell::new(0);
        let report = automatic_update_entrypoint_at_with(
            &state_path,
            now + ChronoDuration::minutes(1),
            linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            || panic!("ready generation must not rescan the installed runtime"),
            || {
                metadata_calls.set(metadata_calls.get() + 1);
                bail!("ready generation must not repeat metadata staging")
            },
            |_version| {
                preparation_calls.set(preparation_calls.get() + 1);
                bail!("ready generation must not create another payload")
            },
        )?;

        assert_eq!(report.status, UpdateStatus::ReadyToInstall);
        assert_eq!(metadata_calls.get(), 0);
        assert_eq!(preparation_calls.get(), 0);
        assert_eq!(fs::read_dir(generation.parent().unwrap())?.count(), 1);
        assert!(runtime.is_file());
        Ok(())
    }

    #[test]
    fn macos_automatic_policy_checks_metadata_but_never_prepares_or_installs() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Idle, now);

        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                macos_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );

        state.status = UpdateStatus::ReadyToInstall;
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                macos_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::None
        );

        state.status = UpdateStatus::Idle;
        state.last_checked_at = Some(now - ChronoDuration::minutes(15));
        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                macos_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            ),
            AutomaticUpdateDecision::CheckStableChannel
        );
    }

    #[test]
    fn macos_real_automatic_entrypoint_absent_state_never_observes_installed_runtime() -> Result<()>
    {
        let temp = tempfile::tempdir()?;
        let state_path = temp.path().join("absent-codex-state.json");
        let installed_observations = std::cell::Cell::new(0);
        let metadata_checks = std::cell::Cell::new(0);
        let preparations = std::cell::Cell::new(0);

        let report = automatic_update_entrypoint_at_with(
            &state_path,
            automatic_update_test_time(),
            macos_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
            || {
                installed_observations.set(installed_observations.get() + 1);
                panic!("macOS metadata-only entrypoint observed installed runtime")
            },
            || {
                metadata_checks.set(metadata_checks.get() + 1);
                Ok(report_from_state(CodexUpdateState::default()))
            },
            |_version| {
                preparations.set(preparations.get() + 1);
                bail!("macOS metadata-only entrypoint prepared a runtime")
            },
        )?;

        assert_eq!(installed_observations.get(), 0);
        assert_eq!(metadata_checks.get(), 1);
        assert_eq!(preparations.get(), 0);
        assert_eq!(report.installed_version, None);
        assert!(!state_path.exists());
        Ok(())
    }

    #[test]
    fn macos_metadata_entrypoint_never_invokes_filesystem_cleanup() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let stale_prepared_artifact = temp.path().join("stale-prepared-generation");
        fs::write(&stale_prepared_artifact, b"must remain")?;
        let metadata_calls = std::cell::Cell::new(0);
        let maintenance_calls = std::cell::Cell::new(0);

        let result = dispatch_update_check(
            AutomaticUpdatePolicy::for_platform(HostPlatform::MacOs)
                .permits_preparation(HostPlatform::MacOs),
            || {
                metadata_calls.set(metadata_calls.get() + 1);
                Ok("metadata-only")
            },
            || {
                maintenance_calls.set(maintenance_calls.get() + 1);
                fs::remove_file(&stale_prepared_artifact)?;
                Ok("maintenance")
            },
        )?;

        assert_eq!(result, "metadata-only");
        assert_eq!(metadata_calls.get(), 1);
        assert_eq!(maintenance_calls.get(), 0);
        assert_eq!(fs::read(&stale_prepared_artifact)?, b"must remain");
        assert!(!automatic_decision_permits_artifact_maintenance(
            &AutomaticUpdateDecision::CheckStableChannel
        ));
        assert!(automatic_decision_permits_artifact_maintenance(
            &AutomaticUpdateDecision::PrepareStableVersion("0.145.0".to_string())
        ));
        Ok(())
    }

    #[test]
    fn metadata_discovery_source_has_no_cleanup_or_retention_calls() {
        let source = include_str!("../codex_update.rs");
        let start = source
            .find("fn check_metadata_with_lock_held(")
            .expect("metadata entrypoint missing");
        let end = source[start..]
            .find("\nfn apply_successful_metadata_check(")
            .map(|offset| start + offset)
            .expect("metadata entrypoint terminator missing");
        let metadata_source = &source[start..end];
        for forbidden in [
            "enforce_updater_retention_at",
            "cleanup_pending_target_at",
            "cleanup_stale_preparation_artifacts",
            "remove_owned_updater_path",
            "remove_dir_all",
            "remove_file",
        ] {
            assert!(
                !metadata_source.contains(forbidden),
                "metadata-only entrypoint contains artifact mutation {forbidden}"
            );
        }
    }

    #[test]
    fn automatic_update_requires_twenty_gib_to_prepare_source() {
        let now = automatic_update_test_time();
        let state = automatic_update_test_state(UpdateStatus::Idle, now);

        assert_eq!(
            automatic_update_decision(
                &state,
                now,
                linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES - 1),
            ),
            AutomaticUpdateDecision::None
        );

        let decision = automatic_update_decision(
            &state,
            now,
            linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
        );
        assert_eq!(
            decision,
            AutomaticUpdateDecision::PrepareStableVersion("0.145.0".to_string())
        );
        assert_eq!(
            background_update_args(&decision),
            ["prepare-codex-update", "--version", "0.145.0", "--json"]
        );
    }

    #[test]
    fn background_deadline_leaves_room_for_inner_build_kill_and_reap() {
        let worst_case_checkout = SOURCE_COMMAND_TIMEOUT + SOURCE_COMMAND_TIMEOUT;
        let fingerprint_and_staging_margin = Duration::from_secs(10 * 60);
        assert!(
            BACKGROUND_UPDATE_DEADLINE
                >= patched_codex::BUILD_COMMAND_TIMEOUT
                    + worst_case_checkout
                    + fingerprint_and_staging_margin
        );
    }

    #[test]
    fn automatic_update_selects_only_one_operation_per_tick() {
        let now = automatic_update_test_time();
        let mut state = automatic_update_test_state(UpdateStatus::Idle, now);
        state.last_checked_at = Some(now - ChronoDuration::minutes(15));

        let decision = automatic_update_decision(
            &state,
            now,
            linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
        );
        assert_eq!(decision, AutomaticUpdateDecision::CheckStableChannel);

        for status in [
            UpdateStatus::Checking,
            UpdateStatus::Preparing,
            UpdateStatus::Installing,
        ] {
            state.status = status;
            assert_eq!(
                automatic_update_decision(
                    &state,
                    now,
                    linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
                ),
                AutomaticUpdateDecision::None
            );
        }
    }

    #[test]
    fn automatic_update_recovers_stale_busy_states_at_operation_specific_deadlines() {
        let now = automatic_update_test_time();
        for (status, stale_age) in [
            (UpdateStatus::Checking, ChronoDuration::minutes(5)),
            (UpdateStatus::Preparing, ChronoDuration::hours(6)),
            (UpdateStatus::Installing, ChronoDuration::minutes(15)),
        ] {
            let mut state = automatic_update_test_state(status, now);
            state.updated_at = now - stale_age;
            assert_eq!(
                automatic_update_decision(
                    &state,
                    now,
                    linux_automatic_context(MINIMUM_SOURCE_PREPARE_BYTES),
                ),
                AutomaticUpdateDecision::CheckStableChannel
            );
        }
    }

    #[test]
    fn automatic_update_check_command_does_not_prepare_or_install() {
        assert_eq!(
            background_update_args(&AutomaticUpdateDecision::CheckStableChannel),
            ["check-codex-update", "--force", "--json"]
        );
    }

    #[test]
    fn updater_operation_lock_defers_second_invoker_and_releases() -> Result<()> {
        let temp = tempfile::tempdir()?;
        let lock_path = temp.path().join("codex-update.lock");
        let first = UpdaterOperationLock::try_acquire_at(&lock_path)?
            .context("first updater lock acquisition was unexpectedly deferred")?;

        assert!(UpdaterOperationLock::try_acquire_at(&lock_path)?.is_none());

        drop(first);
        assert!(UpdaterOperationLock::try_acquire_at(&lock_path)?.is_some());
        Ok(())
    }

    #[test]
    fn installing_status_describes_offline_file_install() {
        let state = CodexUpdateState {
            status: UpdateStatus::Installing,
            last_checked_at: None,
            latest_stable_version: Some("0.134.0".to_string()),
            installed_version: Some("0.133.0".to_string()),
            installed_artifact_manifest_sha256: None,
            prepared_version: Some("0.134.0".to_string()),
            prepared_source_path: None,
            prepared_binary_path: None,
            prepared_artifact_manifest_sha256: None,
            failed_prepare_version: None,
            prepare_retry_not_before: None,
            failed_install_version: None,
            install_retry_not_before: None,
            cleanup_pending_target_path: None,
            unresolved_failure: None,
            install_transaction: None,
            error: None,
            updated_at: Utc::now(),
        };
        let report = report_from_state(state);
        assert!(report.summary.contains("installing"));
        assert!(report.summary.contains("offline"));
        assert!(report.summary.contains("0.134.0"));
        assert_eq!(report.install_command, None);
    }

    #[test]
    fn installed_status_does_not_claim_runtime_activation() {
        let state = automatic_update_test_state(UpdateStatus::Installed, Utc::now());
        let summary = summary_for_state_on_platform(&state, None, HostPlatform::Linux);
        assert!(summary.contains("installed on disk"));
        assert!(summary.contains("runtime activation is separate"));
        assert!(!summary.contains("restarted"));
        assert!(!summary.contains("reloaded"));
    }

    #[test]
    fn status_reports_missing_local_runtime_provenance_actionably() {
        let state = CodexUpdateState::default();
        let summary = summary_for_state_on_platform(&state, None, HostPlatform::Linux);

        assert!(summary.contains("complete provenance/hot-swap validation"));
        assert!(summary.contains("check-codex-update --prepare"));
        assert!(summary.contains("explicitly install"));
    }

    #[test]
    fn shared_runtime_convergence_fixture_round_trips_canonical_v3() -> Result<()> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct SharedFixture {
            request_artifact: crate::reload::HotSwapRequest,
            acknowledgement: crate::reload::HotSwapAck,
        }

        let fixture: SharedFixture = serde_json::from_str(include_str!(
            "../../../../Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json"
        ))?;
        assert_eq!(
            &fixture.request_artifact.binding,
            &fixture.acknowledgement.binding
        );
        assert_eq!(
            fixture.request_artifact.binding.contract_version,
            crate::reload::HOT_SWAP_REQUEST_CONTRACT_VERSION
        );
        assert_eq!(
            fixture.request_artifact.binding.runtime_kind,
            crate::reload::HotSwapRuntimeKind::ExternalAppServer
        );
        assert_eq!(
            fixture
                .request_artifact
                .binding
                .auth_file_identity
                .account_id
                .as_str(),
            "provider-account-01"
        );

        let request_value = serde_json::to_value(&fixture.request_artifact)?;
        let binding = request_value["binding"]
            .as_object()
            .context("fixture request binding must be an object")?;
        assert_eq!(binding.len(), 7);
        assert_eq!(binding["contractVersion"], 3);
        assert_eq!(binding["runtimeKind"], "external-app-server");
        assert!(binding["requestNonce"]
            .as_str()
            .is_some_and(|nonce| !nonce.is_empty()));
        assert!(binding["issuedAtUnixMilliseconds"].as_u64().is_some());

        let process = binding["processIdentity"]
            .as_object()
            .context("fixture process identity must be an object")?;
        assert_eq!(process.len(), 5);
        for field in [
            "pid",
            "ownerUID",
            "executablePath",
            "startSeconds",
            "startMicroseconds",
        ] {
            assert!(process.contains_key(field));
        }
        let executable = binding["kernelExecutableIdentity"]
            .as_object()
            .context("fixture executable identity must be an object")?;
        assert_eq!(executable.len(), 3);
        for field in ["canonicalPath", "device", "inode"] {
            assert!(executable.contains_key(field));
        }
        let auth = binding["authFileIdentity"]
            .as_object()
            .context("fixture auth identity must be an object")?;
        assert_eq!(auth.len(), 5);
        for field in [
            "canonicalPath",
            "device",
            "inode",
            "accountID",
            "completeTokenFingerprint",
        ] {
            assert!(auth.contains_key(field));
        }
        let provider_account_id = auth["accountID"]
            .as_str()
            .context("fixture provider account ID must be a string")?;
        assert_eq!(provider_account_id, "provider-account-01");
        assert!(!provider_account_id.contains('@'));
        assert_eq!(
            serde_json::to_value(&fixture.acknowledgement)?,
            serde_json::from_str::<serde_json::Value>(include_str!(
                "../../../../Tests/Fixtures/RuntimeConvergence/reload-contract-v3.json"
            ))?["acknowledgement"]
        );
        let generated = include_str!("source_app_server_template.rs");
        assert!(generated.contains("format!(\"{pid}.json\")"));
        assert!(generated.contains("codexswitch_validate_v3_binding"));
        assert!(generated.contains("binding.as_object()?.len() != 7"));
        assert!(generated.contains("process.as_object()?.len() != 5"));
        assert!(generated.contains("kernel.as_object()?.len() != 3"));
        assert!(generated.contains("auth_identity.as_object()?.len() != 5"));
        assert!(!generated.contains("format!(\"{pid}.nonce\")"));
        Ok(())
    }

    #[test]
    fn installed_version_ignores_launcher_or_wrapper_without_hot_swap_markers() {
        let temp_dir = tempfile::tempdir().unwrap();
        let binary = temp_dir.path().join("codex");
        fs::write(&binary, "#!/bin/sh\necho 'codex-cli 0.130.0'\n").unwrap();
        set_executable(&binary).unwrap();

        assert_eq!(installed_codex_version_from_path(&binary), None);
    }

    #[test]
    fn installed_version_rejects_hot_swap_binary_without_code_mode_host() {
        let temp_dir = tempfile::tempdir().unwrap();
        let binary = temp_dir.path().join("codex");
        fs::write(
            &binary,
            "#!/bin/sh\n# sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3 codexswitch-hotswap-headless-idle-v1 codexswitch-hotswap-cli-contract-v3 Usage: /goal <objective>\necho 'codex-cli 0.130.0'\n",
        )
        .unwrap();
        set_executable(&binary).unwrap();

        assert_eq!(installed_codex_version_from_path(&binary), None);
    }

    #[test]
    fn installed_version_accepts_only_source_generated_launcher_provenance() {
        let temp_dir = tempfile::tempdir().unwrap();
        let prepared = temp_dir.path().join("prepared-codex/0.130.0/codex");
        fs::create_dir_all(prepared.parent().unwrap()).unwrap();
        fs::write(
            &prepared,
            "#!/bin/sh\n# sighup-verified SIGHUP: auth reloaded hotswap-ack CodexSwitch rotated accounts after a usage limit CodexSwitch rotated accounts after an auth failure Auth changed, opening new WebSocket with fresh credentials codexswitch-runtime-convergence-v3 codexswitch-runtime-rotation-handoff-v1 CodexSwitch account/updated frontend write acknowledged after auth reload codexswitch-hotswap-contract-v3 codexswitch-hotswap-headless-idle-v1 codexswitch-hotswap-cli-contract-v3 Usage: /goal <objective>\necho 'codex-cli 0.130.0'\n",
        )
        .unwrap();
        set_executable(&prepared).unwrap();
        let helper = prepared.with_file_name("codex-code-mode-host");
        fs::write(&helper, b"host").unwrap();
        set_executable(&helper).unwrap();

        let launcher = temp_dir.path().join("patched-codex/codex");
        fs::create_dir_all(launcher.parent().unwrap()).unwrap();
        fs::write(
            &launcher,
            patched_codex::launcher_script_for_runtime(&prepared).unwrap(),
        )
        .unwrap();
        set_executable(&launcher).unwrap();

        assert_eq!(
            installed_codex_version_from_path(&launcher).as_deref(),
            Some("0.130.0")
        );
    }

    #[test]
    fn installed_version_rejects_legacy_remote_fallback_wrapper_without_execution() {
        let temp_dir = tempfile::tempdir().unwrap();
        let launcher = temp_dir.path().join("codex");
        let trace = temp_dir.path().join("executed");
        fs::write(
            &launcher,
            format!(
                "#!/bin/sh\nPATCHED_CODEX='/missing/incomplete-runtime'\nprintf executed > '{}'\nexec /missing/remote-client/codex\n",
                trace.display()
            ),
        )
        .unwrap();
        set_executable(&launcher).unwrap();

        assert_eq!(installed_codex_version_from_path(&launcher), None);
        assert!(!trace.exists());
    }

    #[test]
    fn auth_manager_patch_supports_external_bearer_route_config_shape() {
        let temp_dir = tempfile::tempdir().unwrap();
        let manager = temp_dir.path().join("manager.rs");
        fs::write(
            &manager,
            r#"
	use std::sync::RwLock;
	use serde::Serialize;

	impl CodexAuth {
	    /// Returns the precise kind of credentials backing this authentication.
	    pub fn api_auth_mode(&self) {}
	}

	impl AuthDotJson {
	}

struct AuthManager {
    external_auth: RwLock<Option<Arc<dyn ExternalAuth>>>,
}

impl AuthManager {
    pub fn external_bearer_only(config: AuthRouteConfig) -> Result<Self> {
        Ok(Self {
            external_auth: RwLock::new(Some(
                Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>
            )),
            auth_route_config: None,
        })
    }

    /// Current cached auth (clone) without attempting a refresh.
    pub fn cached_auth(&self) -> Option<CodexAuth> {
        None
    }

	    /// Reloads auth from the active source. Returns whether the auth value changed.
	    pub async fn reload(&self) {
            tracing::info!("Reloaded auth, changed: {changed}");
            guard.auth = new_auth;
    }
}
"#,
        )
        .unwrap();

        patch_auth_manager_source(&manager).unwrap();
        patch_auth_manager_source(&manager).unwrap();

        let patched = fs::read_to_string(manager).unwrap();
        assert!(patched.contains("use std::sync::atomic::AtomicU64;"));
        assert!(patched.contains("auth_generation: AtomicU64,"));
        assert!(patched
            .contains("auth_generation: AtomicU64::new(0),\n            auth_route_config: None,"));
        assert!(patched.contains("pub fn auth_generation(&self) -> u64"));
        assert_eq!(
            patched
                .matches("pub fn codexswitch_auth_fingerprint(&self)")
                .count(),
            2
        );
        assert_eq!(
            patched
                .matches("pub fn codexswitch_provider_account_id(&self)")
                .count(),
            3
        );
        let auth_manager_impl = patched
            .split_once("impl AuthManager {")
            .expect("fixture must retain the AuthManager impl")
            .1;
        assert!(auth_manager_impl.contains("CodexSwitch AuthManager identity bridge"));
        assert!(auth_manager_impl.contains(
            "self.auth_cached()\n            .and_then(|auth| auth.codexswitch_auth_fingerprint())"
        ));
        assert!(auth_manager_impl.contains(
            "self.auth_cached()\n            .and_then(|auth| auth.codexswitch_provider_account_id())"
        ));
        assert!(patched.contains("self.tokens.as_ref()?.account_id.as_deref()?"));
        assert!(patched.contains("pub fn codexswitch_fingerprint(&self)"));
        assert!(patched.contains("fn codexswitch_read_auth_json_bounded("));
        assert!(patched.contains("libc::O_NOFOLLOW | libc::O_CLOEXEC"));
        assert!(patched.contains("AUTH_MAX_BYTES + 1"));
        assert!(patched.contains("pub fn codexswitch_auth_file_fingerprint("));
        assert!(patched.contains("pub fn codexswitch_auth_file_identity("));
        assert!(patched.contains("auth.json has no stable provider account identifier"));
        assert!(patched.contains("pub async fn codexswitch_reload_auth_json_verified"));
        assert!(patched.contains("Self::codexswitch_read_auth_json_bounded(auth_path)?"));
        assert!(patched.contains("CodexAuth::from_auth_dot_json"));
        assert!(!patched.contains("std::fs::read(auth_path)"));
        assert!(patched.contains("*external_auth = None;"));
        assert!(patched.contains("self.auth_generation.fetch_add(1, Ordering::AcqRel);"));
    }

    #[test]
    fn auth_manager_patch_inserts_generation_when_external_auth_initializer_shape_drifts() {
        let temp_dir = tempfile::tempdir().unwrap();
        let manager = temp_dir.path().join("manager.rs");
        fs::write(
            &manager,
            r#"
	use std::sync::RwLock;
	use serde::Serialize;

	impl CodexAuth {
	    /// Returns the precise kind of credentials backing this authentication.
	    pub fn api_auth_mode(&self) {}
	}

	impl AuthDotJson {
	}

struct AuthManager {
    external_auth: RwLock<Option<Arc<dyn ExternalAuth>>>,
}

impl AuthManager {
    pub fn external_bearer_only(config: AuthRouteConfig) -> Arc<Self> {
        Arc::new(Self {
            external_auth: build_external_auth(config),
            auth_route_config: None,
        })
    }

    /// Current cached auth (clone) without attempting a refresh.
    pub fn cached_auth(&self) -> Option<CodexAuth> {
        None
    }

	    /// Reloads auth from the active source. Returns whether the auth value changed.
	    pub async fn reload(&self) {
            tracing::info!("Reloaded auth, changed: {changed}");
            guard.auth = new_auth;
    }
}
"#,
        )
        .unwrap();

        patch_auth_manager_source(&manager).unwrap();

        let patched = fs::read_to_string(manager).unwrap();
        assert!(patched.contains("auth_generation: AtomicU64,"));
        assert!(patched
            .contains("auth_generation: AtomicU64::new(0),\n            auth_route_config: None,"));
        assert_eq!(
            patched
                .matches("auth_generation: AtomicU64::new(0),")
                .count(),
            1
        );
    }

    #[test]
    fn auth_manager_patch_does_not_duplicate_none_initializer_before_route_config() {
        let temp_dir = tempfile::tempdir().unwrap();
        let manager = temp_dir.path().join("manager.rs");
        fs::write(
            &manager,
            r#"
	use std::sync::RwLock;
	use serde::Serialize;

	impl CodexAuth {
	    /// Returns the precise kind of credentials backing this authentication.
	    pub fn api_auth_mode(&self) {}
	}

	impl AuthDotJson {
	}

struct AuthManager {
    external_auth: RwLock<Option<Arc<dyn ExternalAuth>>>,
}

impl AuthManager {
    pub fn from_auth_for_testing() -> Arc<Self> {
        Arc::new(Self {
            external_auth: RwLock::new(None),
            auth_route_config: None,
        })
    }

    /// Current cached auth (clone) without attempting a refresh.
    pub fn cached_auth(&self) -> Option<CodexAuth> {
        None
    }

	    /// Reloads auth from the active source. Returns whether the auth value changed.
	    pub async fn reload(&self) {
            tracing::info!("Reloaded auth, changed: {changed}");
            guard.auth = new_auth;
    }
}
"#,
        )
        .unwrap();

        patch_auth_manager_source(&manager).unwrap();

        let patched = fs::read_to_string(manager).unwrap();
        assert_eq!(
            patched
                .matches("auth_generation: AtomicU64::new(0),")
                .count(),
            1
        );
        assert!(patched
            .contains("external_auth: RwLock::new(None),\n            auth_generation: AtomicU64::new(0),\n            auth_route_config: None,"));
    }

    #[test]
    fn source_patch_declares_injected_libc_dependencies_idempotently() {
        let temp_dir = tempfile::tempdir().unwrap();
        for package in ["codex-login", "codex-app-server"] {
            let manifest = temp_dir.path().join(format!("{package}.toml"));
            fs::write(
                &manifest,
                format!(
                    "[package]\nname = \"{package}\"\n\n[dependencies]\nserde = {{ workspace = true }}\n"
                ),
            )
            .unwrap();

            patch_workspace_dependency_if_present(&manifest, "libc").unwrap();
            patch_workspace_dependency_if_present(&manifest, "libc").unwrap();

            let patched = fs::read_to_string(manifest).unwrap();
            assert_eq!(patched.matches("libc = { workspace = true }").count(), 1);
            assert!(patched.contains(
                "[dependencies]\nlibc = { workspace = true }\nserde = { workspace = true }"
            ));
        }
    }

    #[test]
    fn turn_patch_declares_sha2_dependency_idempotently() {
        let temp_dir = tempfile::tempdir().unwrap();
        let workspace = temp_dir.path().join("codex-rs");
        let core = workspace.join("core");
        let turn = core.join("src/session/turn.rs");
        fs::create_dir_all(turn.parent().unwrap()).unwrap();
        fs::write(
            core.join("Cargo.toml"),
            "[package]\nname = \"codex-core\"\n\n[dependencies]\nserde = { workspace = true }\n",
        )
        .unwrap();
        fs::write(
            workspace.join("Cargo.lock"),
            r#"version = 4

[[package]]
name = "codex-core"
version = "0.0.0"
dependencies = [
 "serde",
 "sha2",
]

[[package]]
name = "codex-utils"
version = "0.0.0"
dependencies = [
 "sha2 0.10.9",
]

[[package]]
name = "sha2"
version = "0.10.9"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "sha2"
version = "0.11.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#,
        )
        .unwrap();

        patch_turn_rotation_dependencies(&turn).unwrap();
        patch_turn_rotation_dependencies(&turn).unwrap();

        let manifest = fs::read_to_string(core.join("Cargo.toml")).unwrap();
        assert_eq!(manifest.matches("sha2 = { workspace = true }").count(), 1);
        let lockfile = fs::read_to_string(workspace.join("Cargo.lock")).unwrap();
        assert!(!lockfile.contains(" \"sha2\",\n"));
        assert!(lockfile.contains(
            "name = \"codex-core\"\nversion = \"0.0.0\"\ndependencies = [\n \"serde\",\n \"sha2 0.10.9\",\n]"
        ));
    }

    #[test]
    fn source_patch_reconciles_placeholder_workspace_lock_versions_idempotently() {
        let temp_dir = tempfile::tempdir().unwrap();
        let manifest = temp_dir.path().join("Cargo.toml");
        let lockfile = temp_dir.path().join("Cargo.lock");
        fs::write(
            &manifest,
            "[workspace]\nmembers = []\n\n[workspace.package]\nversion = \"0.144.4\"\n",
        )
        .unwrap();
        fs::write(
            &lockfile,
            r#"version = 4

[[package]]
name = "codex-app-server"
version = "0.0.0"

[[package]]
name = "codex-login"
version = "0.0.0"

[[package]]
name = "local-explicit-version"
version = "7.8.9"

[[package]]
name = "registry-placeholder"
version = "0.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0000000000000000000000000000000000000000000000000000000000000000"
"#,
        )
        .unwrap();

        patch_placeholder_workspace_lock_versions_if_present(&manifest, &lockfile).unwrap();
        patch_placeholder_workspace_lock_versions_if_present(&manifest, &lockfile).unwrap();

        let patched = fs::read_to_string(lockfile).unwrap();
        assert_eq!(patched.matches("version = \"0.144.4\"").count(), 2);
        assert!(patched.contains("name = \"local-explicit-version\"\nversion = \"7.8.9\""));
        assert!(patched.contains("name = \"registry-placeholder\"\nversion = \"0.0.0\"\nsource = "));
    }

    #[test]
    fn source_patch_updates_injected_libc_lock_entries_idempotently() {
        let temp_dir = tempfile::tempdir().unwrap();
        let lockfile = temp_dir.path().join("Cargo.lock");
        fs::write(
            &lockfile,
            r#"version = 4

[[package]]
name = "codex-app-server"
version = "0.0.0"
dependencies = [
 "anyhow",
 "opentelemetry",
]

[[package]]
name = "codex-login"
version = "0.0.0"
dependencies = [
 "keyring",
 "once_cell",
]

[[package]]
name = "codex-mcp"
version = "0.0.0"

[[package]]
name = "libc"
version = "0.2.182"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#,
        )
        .unwrap();

        for package in ["codex-app-server", "codex-login"] {
            patch_lockfile_dependency_if_present(&lockfile, package, "libc").unwrap();
            patch_lockfile_dependency_if_present(&lockfile, package, "libc").unwrap();
        }

        let patched = fs::read_to_string(lockfile).unwrap();
        assert_eq!(patched.matches(" \"libc\",\n").count(), 2);
        assert!(patched.contains(
            "name = \"codex-app-server\"\nversion = \"0.0.0\"\ndependencies = [\n \"anyhow\",\n \"libc\",\n \"opentelemetry\",\n]"
        ));
        assert!(patched.contains(
            "name = \"codex-login\"\nversion = \"0.0.0\"\ndependencies = [\n \"keyring\",\n \"libc\",\n \"once_cell\",\n]"
        ));
    }

    #[test]
    fn source_patch_rejects_conflicting_workspace_lock_references() {
        let temp_dir = tempfile::tempdir().unwrap();
        let lockfile = temp_dir.path().join("Cargo.lock");
        fs::write(
            &lockfile,
            r#"version = 4

[[package]]
name = "codex-core"
version = "0.0.0"
dependencies = [
 "serde",
]

[[package]]
name = "codex-old"
version = "0.0.0"
dependencies = [
 "sha2 0.10.9",
]

[[package]]
name = "codex-new"
version = "0.0.0"
dependencies = [
 "sha2 0.11.0",
]

[[package]]
name = "sha2"
version = "0.10.9"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "sha2"
version = "0.11.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
"#,
        )
        .unwrap();

        let error =
            patch_lockfile_dependency_if_present(&lockfile, "codex-core", "sha2").unwrap_err();
        assert!(error
            .to_string()
            .contains("conflicting workspace lock references"));
        assert!(!fs::read_to_string(lockfile).unwrap().contains(
            "name = \"codex-core\"\nversion = \"0.0.0\"\ndependencies = [\n \"serde\",\n \"sha2"
        ));
    }

    #[test]
    fn app_server_sighup_patch_targets_processor_auth_manager() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn preload() {
    let auth_manager =
        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
    config_manager.replace_cloud_requirements_loader(auth_manager, config.chatgpt_base_url);
}

async fn run_processor() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            app_server_dir.join("in_process.rs"),
            r#"
fn server_notification_requires_delivery(notification: &ServerNotification) -> bool {
    matches!(
        notification,
        ServerNotification::TurnCompleted(_)
            | ServerNotification::ThreadSettingsUpdated(_)
    )
}

fn start_uninitialized(args: InProcessStartArgs) -> InProcessClientHandle {
    let runtime_handle = tokio::spawn(async move {
        let auth_manager =
            AuthManager::shared_from_config(args.config.as_ref(), args.enable_codex_api_key_env)
                .await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes initial turn input and runs a loop where, at each sampling request,
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(app_server_dir.join("lib.rs")).unwrap();
        let processor_index = patched.find("let processor_handle").unwrap();
        let marker_index = patched.find("sighup-verified").unwrap();
        assert!(
            marker_index > processor_index,
            "SIGHUP reload must patch the auth manager captured by MessageProcessor, not the preload auth manager"
        );
        assert!(patched.contains("SIGHUP: auth reload signal received"));
        assert!(patched.contains("hotswap-ack"));
        assert!(patched.contains("AccountUpdatedNotification"));
        assert!(patched
            .contains("CodexSwitch account/updated frontend write acknowledged after auth reload"));
        assert!(patched.contains("codexswitch_validate_v3_binding"));
        assert!(patched.contains("request_object.get(\"binding\")"));
        assert!(patched.contains(".get(\"authFileIdentity\")"));
        assert!(patched.contains(".get(\"completeTokenFingerprint\")"));
        assert!(patched.contains(".get(\"accountID\")"));
        assert!(patched.contains("codexswitch_reload_auth_json_verified(&auth_path)"));
        assert!(patched.contains("codexswitch_auth_file_identity(&auth_path)"));
        assert!(patched.contains("codexswitch-runtime-convergence-v3"));
        assert!(patched.contains("codexswitch-hotswap-contract-v3"));
        assert!(patched.contains("codexswitch-hotswap-headless-idle-v1"));
        assert!(patched.contains("codexswitch_external_runtime_kind()"));
        assert!(patched.contains("headless-remote-control-app-server"));
        assert!(
            patched.contains("codexswitch_validate_v3_binding(&request, expected_runtime_kind)")
        );
        assert!(patched.contains("BroadcastWithWriteAck"));
        assert!(patched.contains("codexswitch_reload_auth_json_verified"));
        assert!(patched.contains("frontendWriteCount"));
        assert!(patched.contains("initializedFrontendCount"));
        assert!(patched.contains("skippedFrontendCount"));
        assert!(patched.contains("eligibleFrontendCount"));
        assert!(patched.contains("rejectedFrontendCount"));
        assert!(patched.contains("idleListenerReady"));
        assert!(patched.contains("frontend delivery proof failed"));
        assert!(patched.contains("strict app-server has no eligible frontend writer"));
        assert!(patched.contains("did not complete every eligible frontend write"));
        assert!(patched.contains("requestNonce"));
        assert!(patched.contains("processIdentity"));
        assert!(patched.contains("kernelExecutableIdentity"));
        assert!(patched.contains("loadedTokenFingerprint"));
        assert!(patched.contains("activeTokenFingerprint"));
        assert!(!patched.contains(".nonce"));
        assert!(!patched.contains("expectedAuthHash"));
        assert!(patched.contains("fn codexswitch_read_bounded_request("));
        assert!(patched.contains("REQUEST_MAX_BYTES + 1"));
        assert!(patched.contains("libc::O_NOFOLLOW | libc::O_CLOEXEC"));
        assert!(!patched.contains("std::fs::read_to_string(&request_path)"));
        assert!(
            patched
                .find("CodexSwitch account/updated frontend write acknowledged after auth reload")
                .unwrap()
                < patched.rfind("hotswap-ack").unwrap(),
            "the desktop ACK must be written only after account/updated is queued"
        );
        assert_eq!(patched.matches("SIGHUP: auth reloaded").count(), 2);

        let in_process_patched = fs::read_to_string(app_server_dir.join("in_process.rs")).unwrap();
        let auth_index = in_process_patched
            .find("AuthManager::shared_from_config")
            .unwrap();
        let in_process_ack_index = in_process_patched
            .find("SIGHUP: auth reload signal received by in-process app-server")
            .unwrap();
        assert!(
            in_process_ack_index > auth_index,
            "foreground CLI uses the in-process app-server, so its auth manager must acknowledge SIGHUP"
        );
        assert!(in_process_patched.contains("hotswap-ack"));
        assert!(in_process_patched.contains("ServerNotification::AccountUpdated(_)"));
        assert!(in_process_patched.contains("codexswitch-hotswap-cli-contract-v3"));
        assert!(in_process_patched
            .contains("codexswitch_validate_v3_binding(&request, \"local-interactive-cli\")"));
        assert!(in_process_patched.contains("\"authGeneration\": auth_generation"));
        assert!(in_process_patched.contains("\"reconnectReady\": true"));
        assert!(in_process_patched.contains("\"frontendNotified\": false"));
        assert!(in_process_patched.contains("\"frontendWriteCount\": 0"));
        assert!(in_process_patched.contains("processIdentity"));
        assert!(in_process_patched.contains("kernelExecutableIdentity"));
        assert!(in_process_patched.contains("loadedTokenFingerprint"));
        assert!(in_process_patched.contains("activeTokenFingerprint"));
        assert!(!in_process_patched.contains(".nonce"));
        assert!(in_process_patched.contains("fn codexswitch_read_bounded_request("));
        assert!(!in_process_patched.contains("std::fs::read_to_string(&request_path)"));
        assert!(!in_process_patched.contains("BroadcastWithWriteAck"));

        let closed_guard_index = in_process_patched
            .find("outgoing_for_signal.is_closed()")
            .unwrap();
        let nonce_read_index = in_process_patched
            .find("codexswitch_read_bounded_request(&request_path)")
            .unwrap();
        assert!(closed_guard_index < nonce_read_index);
        assert!(!in_process_patched.contains("std::fs::remove_file(request_path)"));

        let tui_patched = fs::read_to_string(tui_dir.join("lib.rs")).unwrap();
        assert!(!tui_patched.contains("sighup-verified-tui"));
        assert!(!tui_patched.contains("foreground session ignores signal"));
    }

    #[test]
    fn app_server_sighup_patch_accepts_shared_auth_manager_anchor() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn run_app_server() {
    let auth_manager =
        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;

    let remote_control_requested = runtime_options.remote_control_enabled;
    let processor_handle = tokio::spawn({
        let auth_manager = Arc::clone(&auth_manager);
        let processor = MessageProcessor::new(MessageProcessorArgs {
            auth_manager,
        });
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes a user message as input and runs a loop where, at each sampling request, the model
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(app_server_dir.join("lib.rs")).unwrap();
        let shared_auth_index = patched.find("AuthManager::shared_from_config").unwrap();
        let marker_index = patched.find("SIGHUP: auth reload signal received").unwrap();
        let remote_control_index = patched.find("remote_control_requested").unwrap();
        assert!(marker_index > shared_auth_index);
        assert!(marker_index < remote_control_index);
        assert!(patched.contains("hotswap-ack"));
        assert!(patched
            .contains("CodexSwitch account/updated frontend write acknowledged after auth reload"));
    }

    #[test]
    fn app_server_patch_upgrades_legacy_sighup_without_ack() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn preload() {
    let auth_manager =
        AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
    #[cfg(unix)]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let marker_dir = std::path::PathBuf::from(home).join(".codexswitch");
            let _ = std::fs::create_dir_all(&marker_dir);
            let _ = std::fs::write(marker_dir.join("sighup-verified"), "app-server\n");
        }

        let auth_for_signal = auth_manager.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sighup = signal(SignalKind::hangup()).unwrap();
            while sighup.recv().await.is_some() {
                let changed = auth_for_signal.reload().await;
                if changed {
                    tracing::info!("SIGHUP: auth reloaded from disk (tokens changed)");
                } else {
                    tracing::debug!("SIGHUP: auth reloaded from disk (no change)");
                }
            }
        });
    }
    config_manager.replace_cloud_requirements_loader(auth_manager, config.chatgpt_base_url);
}

async fn run_processor() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes a user message as input and runs a loop where, at each sampling request, the model
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(app_server_dir.join("lib.rs")).unwrap();
        let processor_index = patched.find("let processor_handle").unwrap();
        let ack_index = patched.find("hotswap-ack").unwrap();
        assert!(
            ack_index > processor_index,
            "legacy SIGHUP-only patches must be upgraded at the processor auth manager"
        );
        assert!(patched.contains("SIGHUP: auth reload signal received"));
    }

    #[test]
    fn core_turn_patch_rotates_and_retries_once_on_usage_limit() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn run_processor() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

/// Takes a user message as input and runs a loop where, at each sampling request, the model
async fn run_turn() {
    let mut retries = 0;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(turn_dir.join("turn.rs")).unwrap();
        assert!(patched.contains("codexswitch_rotate_after_usage_limit"));
        assert!(patched.contains("codexswitch_usage_limit_retry_attempted"));
        assert!(patched.contains("codexswitch_rotate_after_auth_failure"));
        assert!(patched.contains("codexswitch_auth_reload_retry_attempted"));
        assert!(patched.contains("codexswitch_auth_rotation_retry_attempted"));
        assert!(patched.contains("rotate-now"));
        assert_eq!(patched.matches(".arg(\"rotate-now\")").count(), 1);
        assert!(!patched.contains(".arg(\"--no-reload\")"));
        assert_eq!(patched.matches(".arg(\"--auth\")").count(), 1);
        assert!(patched.contains(".arg(\"--receipt-nonce\")"));
        assert_eq!(patched.matches(".arg(&auth_path)").count(), 1);
        assert!(patched.contains("codexswitch_resolve_linux_managed_control_cli_at"));
        assert!(patched.contains("release-manifest.tsv"));
        assert!(patched.contains("codexswitch-release-v3"));
        assert!(patched.contains("cli_sha256"));
        assert!(patched.contains("/proc/self/fd/"));
        assert!(patched.contains("control_cli.is_still_current()"));
        assert!(!patched.contains("std::env::var(\"CODEXSWITCH_CLI\")"));
        assert!(!patched.contains("\"codexswitch-cli\".to_string()"));
        assert!(patched.contains("fn codexswitch_run_bounded_rotation("));
        assert!(patched.contains("fn codexswitch_capture_bounded_stream<R>("));
        assert!(patched.contains(".stdout(std::process::Stdio::piped())"));
        assert!(patched.contains("child.kill().await"));
        assert!(patched.contains("child.wait().await"));
        assert!(!patched.contains(".output()"));
        assert!(patched.contains("codexswitch_read_bounded_json(&ack_path, ACK_MAX_BYTES)"));
        assert!(patched.contains("codexswitch_read_bounded_json(&request_path, REQUEST_MAX_BYTES)"));
        assert!(!patched.contains("std::fs::read(&ack_path)"));
        assert!(patched.contains("fn codexswitch_bound_auth_path_v3("));
        assert!(patched.contains("fn codexswitch_bound_auth_path_for_external_change_v3("));
        assert!(patched.contains("allow_auth_file_identity_drift"));
        assert!(patched.contains("codexswitch_current_start_identity()"));
        assert!(patched.contains("\"local-interactive-cli\""));
        assert!(patched.contains("processIdentity"));
        assert!(patched.contains("binding.get(\"requestNonce\")"));
        assert!(patched.contains("ack.get(\"binding\")? != binding"));
        assert!(patched.contains("codexswitch_request_nonce_matches_receipt"));
        assert!(patched.contains("issued_not_before.is_some_and"));
        assert!(patched.contains("acknowledged_at < issued_at"));
        assert!(patched.contains("ACK_MAX_AGE_MILLISECONDS"));
        assert!(patched.contains("loadedTokenFingerprint"));
        assert!(patched.contains("activeTokenFingerprint"));
        assert!(patched.contains("codexswitch_auth_file_identity(&auth_path)"));
        assert!(patched.contains("fn codexswitch_verified_rotation_result("));
        assert!(patched.contains("codexswitch-runtime-rotation-handoff-v1"));
        assert!(patched.contains("report.get(\"receiptNonce\")"));
        assert!(patched.contains("report.get(\"runtimeConverged\")"));
        assert!(patched.contains("report.get(\"topologyVerified\")"));
        assert!(patched.contains("report.get(\"requestCount\")"));
        assert!(patched.contains("report.get(\"sighupSentProcesses\")"));
        assert!(patched.contains("report.get(\"acknowledgedRequestNonces\")"));
        assert!(patched.contains("report.get(\"nextTokenFingerprint\")"));
        let rotation_start = patched
            .find("async fn codexswitch_rotate_after_failure(")
            .unwrap();
        let rotation_end = patched[rotation_start..]
            .find("async fn codexswitch_rotate_after_usage_limit(")
            .map(|offset| rotation_start + offset)
            .unwrap();
        let rotation_source = &patched[rotation_start..rotation_end];
        assert_eq!(
            rotation_source
                .matches("codexswitch_reload_auth_json_verified(&auth_path)")
                .count(),
            1,
            "post-ACK convergence permits at most one fallback reload"
        );
        assert!(rotation_source.contains("if !manager_already_matches_handoff"));
        assert!(rotation_source.contains("own_handoff.auth_generation"));
        assert!(rotation_source.contains("pre_rotation_auth_generation"));
        assert!(!rotation_source.contains("if !changed"));
        let external_reload_start = patched
            .find("async fn codexswitch_reload_changed_external_auth(")
            .unwrap();
        let external_reload_end = patched[external_reload_start..]
            .find("async fn codexswitch_rotate_after_failure(")
            .map(|offset| external_reload_start + offset)
            .unwrap();
        let external_reload_source = &patched[external_reload_start..external_reload_end];
        assert_eq!(
            external_reload_source
                .matches("codexswitch_reload_auth_json_verified(&auth_path)")
                .count(),
            1,
            "external auth recovery permits at most one fallback reload"
        );
        assert!(external_reload_source.contains("codexswitch_external_auth_handoff_matches("));
        assert!(external_reload_source.contains("request_auth_generation"));
        assert!(external_reload_source.contains("bound_handoff_is_still_current"));
        assert!(
            external_reload_source.contains("post_reload_generation <= generation_before_fallback")
        );
        assert!(!external_reload_source.contains("if !changed"));
        assert!(!patched.contains("~/.codex/auth.json"));
        assert!(patched.contains("CODEXSWITCH_ROTATE_TIMEOUT_SECONDS"));
        assert!(patched.contains("const DEFAULT_SECONDS: u64 = 120"));
        assert!(patched.contains("const MAX_SECONDS: u64 = 600"));
        assert!(patched.contains("codexswitch_rotation_timeout()"));
        assert!(!patched.contains("std::time::Duration::from_secs(10)"));
        assert!(patched.contains("usage_limit"));
        assert!(patched.contains("token_expired"));
        assert!(patched.contains("2592000"));
        assert!(patched.contains("token_invalidated"));
        assert!(patched.contains("401"));
        assert!(patched.contains("continue;"));
        assert_eq!(
            patched
                .matches("let mut codexswitch_usage_limit_retry_attempted = false;")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("let mut codexswitch_auth_reload_retry_attempted = false;")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("let mut codexswitch_auth_rotation_retry_attempted = false;")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("codexswitch_request_auth_generation,\n                        )\n                        .await")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("let codexswitch_request_auth_generation = turn_context")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("codexswitch_rotate_after_usage_limit(&sess, &turn_context).await")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("codexswitch_rotate_after_auth_failure(&sess, &turn_context).await")
                .count(),
            1
        );
        let successful_status_index = patched.find("if !output.status.success()").unwrap();
        let reload_index = patched[successful_status_index..]
            .find("codexswitch_reload_auth_json_verified(&auth_path)")
            .map(|index| successful_status_index + index)
            .unwrap();
        assert!(reload_index > successful_status_index);
    }

    #[test]
    fn interrupted_turn_direct_contract_rejects_stale_ack_and_bad_counts() {
        let receipt = "37f84870-9b39-45ae-aee9-3e0a63e1f989";
        let request = format!("{receipt}:1a7c3ffb-bfd8-4719-9b45-c2e350469d9c");
        assert!(interrupted_turn_receipt_ack_is_current(
            receipt, &request, 1_001, 1_002, 1_000,
        ));
        assert!(!interrupted_turn_receipt_ack_is_current(
            receipt, &request, 999, 1_002, 1_000,
        ));
        assert!(!interrupted_turn_receipt_ack_is_current(
            "0cfe69d8-d7f8-4640-84c1-d88acd278983",
            &request,
            1_001,
            1_002,
            1_000,
        ));

        assert!(interrupted_turn_report_counts_are_complete(
            2, 2, 2, 2, 0, 0, true,
        ));
        assert!(!interrupted_turn_report_counts_are_complete(
            2, 2, 2, 1, 0, 0, true,
        ));
        assert!(!interrupted_turn_report_counts_are_complete(
            2, 2, 2, 2, 0, 0, false,
        ));
    }

    #[cfg(unix)]
    struct ManagedControlFixture {
        _temporary: tempfile::TempDir,
        home: PathBuf,
        install_root: PathBuf,
        release_dir: PathBuf,
        release_id: String,
        cli: PathBuf,
        manifest: PathBuf,
        current: PathBuf,
        public: PathBuf,
        cli_sha256: String,
    }

    #[cfg(unix)]
    impl ManagedControlFixture {
        fn new() -> Self {
            use std::os::unix::fs::{symlink, PermissionsExt};

            let temporary = tempfile::tempdir().unwrap();
            let root = fs::canonicalize(temporary.path()).unwrap();
            let home = root.join("home");
            let local = home.join(".local");
            let bin = local.join("bin");
            let share = local.join("share");
            let install_root = share.join("codexswitch");
            let releases = install_root.join("releases");
            let release_id = format!("0.1.0-{}", "a".repeat(40));
            let release_dir = releases.join(&release_id);
            fs::create_dir_all(&release_dir).unwrap();
            fs::create_dir_all(&bin).unwrap();
            for directory in [&home, &local, &bin, &share, &install_root, &releases] {
                fs::set_permissions(directory, fs::Permissions::from_mode(0o755)).unwrap();
            }

            let cli = release_dir.join("codexswitch-cli");
            let cli_bytes = b"deterministic-codexswitch-control-fixture\n";
            fs::write(&cli, cli_bytes).unwrap();
            fs::set_permissions(&cli, fs::Permissions::from_mode(0o555)).unwrap();
            let cli_sha256 = ring::digest::digest(&ring::digest::SHA256, cli_bytes)
                .as_ref()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect::<String>();
            let manifest = release_dir.join("release-manifest.tsv");
            fs::write(&manifest, Self::manifest_contents(&release_id, &cli_sha256)).unwrap();
            fs::set_permissions(&manifest, fs::Permissions::from_mode(0o444)).unwrap();
            fs::set_permissions(&release_dir, fs::Permissions::from_mode(0o555)).unwrap();

            let current = install_root.join("current");
            symlink(Path::new("releases").join(&release_id), &current).unwrap();
            let public = bin.join("codexswitch-cli");
            symlink(current.join("codexswitch-cli"), &public).unwrap();

            Self {
                _temporary: temporary,
                home,
                install_root,
                release_dir,
                release_id,
                cli,
                manifest,
                current,
                public,
                cli_sha256,
            }
        }

        fn manifest_contents(release_id: &str, cli_sha256: &str) -> String {
            let hash = "1".repeat(64);
            format!(
                "format\tcodexswitch-release-v3\n\
                 release_id\t{release_id}\n\
                 git_sha\t{}\n\
                 package_version\t0.1.0\n\
                 build_epoch\t1783915200\n\
                 cli_version\tcodexswitch-cli 0.1.0\n\
                 cli_sha256\t{cli_sha256}\n\
                 codex_source_sha\t{}\n\
                 upstream_codex_git_sha\t{}\n\
                 source_patch_sha256\t{hash}\n\
                 sourcePatchSha256\t{hash}\n\
                 artifact_manifest_sha256\t{hash}\n\
                 artifact_total_bytes\t4096\n\
                 codex_version\t0.144.6\n\
                 codex_sha256\t{hash}\n\
                 codex_code_mode_host_sha256\t{hash}\n\
                 codex_marker_contract\tcodexswitch-hotswap-full-v3\n\
                 systemd_payload\tcodexswitch.service\n\
                 codexswitch_unit_sha256\t{hash}\n\
                 codexswitch_dropin_sha256\t{hash}\n\
                 app_server_unit_sha256\t{hash}\n\
                 app_server_dropin_sha256\t{hash}\n",
                "b".repeat(40),
                "c".repeat(40),
                "c".repeat(40),
            )
        }

        fn resolve(&self) -> Option<CodexSwitchControlCli> {
            codexswitch_resolve_linux_managed_control_cli_at(&self.home, unsafe { libc::geteuid() })
        }

        fn rewrite_manifest(&self, contents: &str) {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&self.release_dir, fs::Permissions::from_mode(0o755)).unwrap();
            fs::set_permissions(&self.manifest, fs::Permissions::from_mode(0o644)).unwrap();
            fs::write(&self.manifest, contents).unwrap();
            fs::set_permissions(&self.manifest, fs::Permissions::from_mode(0o444)).unwrap();
            fs::set_permissions(&self.release_dir, fs::Permissions::from_mode(0o555)).unwrap();
        }
    }

    #[cfg(unix)]
    #[test]
    fn interrupted_turn_resolves_exact_production_managed_cli_layout() {
        let fixture = ManagedControlFixture::new();
        let resolved = fixture.resolve().expect("production layout must resolve");
        assert_eq!(resolved.canonical_path, fixture.cli);
        assert_eq!(resolved.expected_sha256, fixture.cli_sha256);
        assert!(resolved.is_still_current());
    }

    #[cfg(unix)]
    #[test]
    fn interrupted_turn_rejects_unmanaged_escaping_or_ambiguous_links() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let arbitrary = ManagedControlFixture::new();
        fs::remove_file(&arbitrary.public).unwrap();
        symlink(&arbitrary.cli, &arbitrary.public).unwrap();
        assert!(arbitrary.resolve().is_none());

        let escaping = ManagedControlFixture::new();
        fs::remove_file(&escaping.current).unwrap();
        symlink(Path::new("../outside"), &escaping.current).unwrap();
        assert!(escaping.resolve().is_none());

        let terminal_link = ManagedControlFixture::new();
        fs::set_permissions(
            &terminal_link.release_dir,
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        fs::remove_file(&terminal_link.cli).unwrap();
        symlink("release-manifest.tsv", &terminal_link.cli).unwrap();
        fs::set_permissions(
            &terminal_link.release_dir,
            fs::Permissions::from_mode(0o555),
        )
        .unwrap();
        assert!(terminal_link.resolve().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn interrupted_turn_rejects_wrong_owner_writable_release_and_bad_manifest_binding() {
        use std::os::unix::fs::PermissionsExt;

        let wrong_owner = ManagedControlFixture::new();
        assert!(codexswitch_resolve_linux_managed_control_cli_at(
            &wrong_owner.home,
            unsafe { libc::geteuid() }.wrapping_add(1),
        )
        .is_none());

        let writable = ManagedControlFixture::new();
        fs::set_permissions(&writable.release_dir, fs::Permissions::from_mode(0o575)).unwrap();
        assert!(writable.resolve().is_none());

        let wrong_hash = ManagedControlFixture::new();
        wrong_hash.rewrite_manifest(&ManagedControlFixture::manifest_contents(
            &wrong_hash.release_id,
            &"0".repeat(64),
        ));
        assert!(wrong_hash.resolve().is_none());

        let missing_binding = ManagedControlFixture::new();
        let malformed = ManagedControlFixture::manifest_contents(
            &missing_binding.release_id,
            &missing_binding.cli_sha256,
        )
        .lines()
        .filter(|line| !line.starts_with("cli_sha256\t"))
        .collect::<Vec<_>>()
        .join("\n")
            + "\n";
        missing_binding.rewrite_manifest(&malformed);
        assert!(missing_binding.resolve().is_none());
    }

    #[cfg(unix)]
    #[test]
    fn interrupted_turn_detects_current_link_replacement_after_resolution() {
        use std::os::unix::fs::symlink;

        let fixture = ManagedControlFixture::new();
        let resolved = fixture.resolve().expect("production layout must resolve");
        fs::remove_file(&fixture.current).unwrap();
        symlink(Path::new("releases/replaced-release"), &fixture.current).unwrap();
        assert!(!resolved.is_still_current());
    }

    #[cfg(unix)]
    #[derive(Clone, Copy)]
    struct AuthConvergenceSnapshot {
        fingerprint: &'static str,
        provider_account_id: &'static str,
        generation: u64,
    }

    #[cfg(unix)]
    fn interrupted_turn_auth_convergence_harness(
        initial: AuthConvergenceSnapshot,
        handoff: AuthConvergenceSnapshot,
        pre_rotation_generation: u64,
        reload_results: &[AuthConvergenceSnapshot],
    ) -> (bool, usize) {
        let matches = |snapshot: AuthConvergenceSnapshot| {
            codexswitch_auth_handoff_matches(
                Some(snapshot.fingerprint),
                Some(snapshot.provider_account_id),
                snapshot.generation,
                handoff.fingerprint,
                handoff.provider_account_id,
                handoff.generation,
                pre_rotation_generation,
            )
        };
        if matches(initial) {
            return (true, 0);
        }
        let Some(after_reload) = reload_results.first().copied() else {
            return (false, 1);
        };
        (matches(after_reload), 1)
    }

    #[cfg(unix)]
    #[test]
    fn interrupted_turn_auth_convergence_accepts_already_converged_or_one_reload() {
        let old = AuthConvergenceSnapshot {
            fingerprint: "old",
            provider_account_id: "old-account",
            generation: 11,
        };
        let handoff = AuthConvergenceSnapshot {
            fingerprint: "new",
            provider_account_id: "new-account",
            generation: 12,
        };
        assert_eq!(
            interrupted_turn_auth_convergence_harness(handoff, handoff, 11, &[]),
            (true, 0),
            "the SIGHUP-converged manager must not be reloaded again"
        );
        assert_eq!(
            interrupted_turn_auth_convergence_harness(old, handoff, 11, &[handoff]),
            (true, 1),
            "a manager that has not observed SIGHUP gets one fallback reload"
        );
    }

    #[cfg(unix)]
    #[test]
    fn interrupted_turn_external_auth_accepts_receipt_bound_sighup_without_fallback_reload() {
        let request_generation = 41;
        let handoff = AuthConvergenceSnapshot {
            fingerprint: "new-full-token-fingerprint",
            provider_account_id: "new-account",
            generation: 42,
        };
        let already_converged = codexswitch_external_auth_handoff_matches(
            Some(handoff.fingerprint),
            Some(handoff.provider_account_id),
            handoff.generation,
            Some(handoff.fingerprint),
            Some(handoff.provider_account_id),
            handoff.fingerprint,
            handoff.provider_account_id,
            handoff.generation,
            request_generation,
        );
        assert!(already_converged);
        assert!(!codexswitch_external_auth_handoff_matches(
            Some(handoff.fingerprint),
            Some(handoff.provider_account_id),
            request_generation,
            Some(handoff.fingerprint),
            Some(handoff.provider_account_id),
            handoff.fingerprint,
            handoff.provider_account_id,
            handoff.generation,
            request_generation,
        ));
        assert!(!codexswitch_external_auth_handoff_matches(
            Some(handoff.fingerprint),
            Some("wrong-account"),
            handoff.generation,
            Some(handoff.fingerprint),
            Some(handoff.provider_account_id),
            handoff.fingerprint,
            handoff.provider_account_id,
            handoff.generation,
            request_generation,
        ));
        assert!(!codexswitch_external_auth_handoff_matches(
            Some(handoff.fingerprint),
            Some(handoff.provider_account_id),
            handoff.generation,
            Some("wrong-disk-fingerprint"),
            Some(handoff.provider_account_id),
            handoff.fingerprint,
            handoff.provider_account_id,
            handoff.generation,
            request_generation,
        ));
    }

    #[cfg(unix)]
    #[test]
    fn interrupted_turn_auth_convergence_rejects_stale_or_wrong_ack_without_second_reload() {
        let handoff = AuthConvergenceSnapshot {
            fingerprint: "new",
            provider_account_id: "new-account",
            generation: 12,
        };
        let stale_generation = AuthConvergenceSnapshot {
            generation: 11,
            ..handoff
        };
        assert_eq!(
            interrupted_turn_auth_convergence_harness(
                stale_generation,
                stale_generation,
                11,
                &[stale_generation],
            ),
            (false, 1)
        );

        let wrong_fingerprint = AuthConvergenceSnapshot {
            fingerprint: "wrong",
            ..handoff
        };
        assert_eq!(
            interrupted_turn_auth_convergence_harness(
                wrong_fingerprint,
                handoff,
                11,
                &[wrong_fingerprint],
            ),
            (false, 1)
        );
        let wrong_account = AuthConvergenceSnapshot {
            provider_account_id: "wrong-account",
            ..handoff
        };
        assert_eq!(
            interrupted_turn_auth_convergence_harness(wrong_account, handoff, 11, &[wrong_account]),
            (false, 1)
        );

        assert_eq!(
            interrupted_turn_auth_convergence_harness(
                wrong_fingerprint,
                handoff,
                11,
                &[wrong_fingerprint, handoff],
            ),
            (false, 1),
            "a failed fallback must not consume a second reload result"
        );
    }

    #[test]
    fn interrupted_turn_direct_retry_budget_is_one_auth_retry_plus_one_rotation_retry() {
        let mut auth = InterruptedTurnRetryBudget::default();
        assert_eq!(
            auth.auth_failure(true, true),
            Some(InterruptedTurnRetryAction::ExternalAuthRetry)
        );
        assert_eq!(
            auth.auth_failure(true, true),
            Some(InterruptedTurnRetryAction::RotationRetry)
        );
        assert_eq!(auth.auth_failure(true, true), None);

        let mut unchanged_auth = InterruptedTurnRetryBudget::default();
        assert_eq!(
            unchanged_auth.auth_failure(false, false),
            Some(InterruptedTurnRetryAction::RotationRetry)
        );
        assert_eq!(unchanged_auth.auth_failure(false, false), None);

        let mut usage = InterruptedTurnRetryBudget::default();
        assert_eq!(
            usage.usage_failure(),
            Some(InterruptedTurnRetryAction::RotationRetry)
        );
        assert_eq!(usage.usage_failure(), None);
    }

    #[test]
    fn core_turn_patch_upgrades_existing_usage_limit_rotation_for_auth_failures() {
        let temp_dir = tempfile::tempdir().unwrap();
        let source_dir = temp_dir.path();
        let app_server_dir = source_dir.join("codex-rs/app-server/src");
        let turn_dir = source_dir.join("codex-rs/core/src/session");
        let tui_dir = source_dir.join("codex-rs/tui/src");
        fs::create_dir_all(&app_server_dir).unwrap();
        fs::create_dir_all(&turn_dir).unwrap();
        fs::create_dir_all(&tui_dir).unwrap();
        fs::write(
            app_server_dir.join("lib.rs"),
            r#"
async fn run_processor() {
    let processor_handle = tokio::spawn({
        let auth_manager =
            AuthManager::shared_from_config(&config, /*enable_codex_api_key_env*/ false).await;
        let processor = MessageProcessor::new(auth_manager.clone());
    });
}
"#,
        )
        .unwrap();
        fs::write(
            turn_dir.join("turn.rs"),
            r#"
use codex_protocol::error::CodexErr;

#[cfg(unix)]
async fn codexswitch_rotate_after_usage_limit(sess: &Session, turn_context: &TurnContext) -> bool {
    let cli = std::env::var("CODEXSWITCH_CLI").unwrap_or_else(|_| "codexswitch-cli".to_string());
    let rotate = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::process::Command::new(cli)
            .arg("rotate-now")
            .arg("--reason")
            .arg("usage_limit")
            .arg("--cooldown-seconds")
            .arg("18000")
            .arg("--json")
            .output(),
    )
    .await;

    let Ok(Ok(output)) = rotate else {
        warn!("CodexSwitch usage-limit rotation failed or timed out");
        return false;
    };
    if !output.status.success() {
        return false;
    }

    if let Some(auth_manager) = turn_context.auth_manager.as_ref() {
        auth_manager.reload().await;
    }
    sess.send_event(
        turn_context,
        EventMsg::Warning(WarningEvent {
            message: "CodexSwitch rotated accounts after a usage limit and is retrying this turn.".to_string(),
        }),
    )
    .await;
    true
}

#[cfg(not(unix))]
async fn codexswitch_rotate_after_usage_limit(_sess: &Session, _turn_context: &TurnContext) -> bool {
    false
}

/// Takes a user message as input and runs a loop where, at each sampling request, the model
async fn run_turn() {
    let mut retries = 0;
    let mut codexswitch_usage_limit_retry_attempted = false;
    loop {
        match try_run_sampling_request().await {
            Ok(output) => return Ok(output),
            Err(CodexErr::UsageLimitReached(e)) => {
                let rate_limits = e.rate_limits.clone();
                if let Some(rate_limits) = rate_limits {
                    sess.update_rate_limits(&turn_context, *rate_limits).await;
                }
                if !codexswitch_usage_limit_retry_attempted
                    && codexswitch_rotate_after_usage_limit(&sess, &turn_context).await
                {
                    codexswitch_usage_limit_retry_attempted = true;
                    continue;
                }
                return Err(CodexErr::UsageLimitReached(e));
            }
            Err(err) => err,
        };
    }
}
"#,
        )
        .unwrap();
        fs::write(
            tui_dir.join("lib.rs"),
            "pub async fn main() {\n    // Initialize high-fidelity session event logging if enabled.\n}\n",
        )
        .unwrap();

        patch_codex_source(source_dir).unwrap();

        let patched = fs::read_to_string(turn_dir.join("turn.rs")).unwrap();
        assert_eq!(
            patched
                .matches("async fn codexswitch_rotate_after_usage_limit")
                .count(),
            2,
            "unix and non-unix usage helpers should not be duplicated"
        );
        assert!(patched.contains("codexswitch_rotate_after_auth_failure"));
        assert!(patched.contains("codexswitch_auth_reload_retry_attempted"));
        assert!(patched.contains("codexswitch_auth_rotation_retry_attempted"));
        assert!(patched.contains("codexswitch_is_auth_invalidated_error(&err)"));
        assert!(patched.contains("\"token_expired\""));
        assert!(patched.contains("\"2592000\""));
        assert_eq!(patched.matches(".arg(\"rotate-now\")").count(), 1);
        assert!(!patched.contains(".arg(\"--no-reload\")"));
        assert_eq!(patched.matches(".arg(\"--auth\")").count(), 1);
        assert!(patched.contains(".arg(\"--receipt-nonce\")"));
        assert_eq!(patched.matches(".arg(&auth_path)").count(), 1);
        assert!(patched.contains("codexswitch_resolve_linux_managed_control_cli_at"));
        assert!(patched.contains("release-manifest.tsv"));
        assert!(patched.contains("cli_sha256"));
        assert!(patched.contains("control_cli.execution_path()"));
        assert!(!patched.contains("std::env::var(\"CODEXSWITCH_CLI\")"));
        assert!(!patched.contains("\"codexswitch-cli\".to_string()"));
        assert!(patched.contains("fn codexswitch_run_bounded_rotation("));
        assert!(patched.contains("fn codexswitch_capture_bounded_stream<R>("));
        assert!(patched.contains(".stdout(std::process::Stdio::piped())"));
        assert!(patched.contains("child.kill().await"));
        assert!(patched.contains("child.wait().await"));
        assert!(!patched.contains(".output()"));
        assert!(patched.contains("codexswitch_read_bounded_json(&ack_path, ACK_MAX_BYTES)"));
        assert!(patched.contains("codexswitch_read_bounded_json(&request_path, REQUEST_MAX_BYTES)"));
        assert!(!patched.contains("std::fs::read(&ack_path)"));
        assert!(patched.contains("fn codexswitch_bound_auth_path_v3("));
        assert!(patched.contains("fn codexswitch_bound_auth_path_for_external_change_v3("));
        assert!(patched.contains("allow_auth_file_identity_drift"));
        assert!(patched.contains("codexswitch_current_start_identity()"));
        assert!(patched.contains("processIdentity"));
        assert!(patched.contains("ack.get(\"binding\")? != binding"));
        assert!(patched.contains("codexswitch_request_nonce_matches_receipt"));
        assert!(patched.contains("issued_not_before.is_some_and"));
        assert!(patched.contains("acknowledged_at < issued_at"));
        assert!(patched.contains("ACK_MAX_AGE_MILLISECONDS"));
        assert!(patched.contains("loadedTokenFingerprint"));
        assert!(patched.contains("activeTokenFingerprint"));
        assert!(patched.contains("codexswitch_auth_file_identity(&auth_path)"));
        assert!(patched.contains("fn codexswitch_verified_rotation_result("));
        assert!(patched.contains("codexswitch-runtime-rotation-handoff-v1"));
        assert!(patched.contains("report.get(\"receiptNonce\")"));
        assert!(patched.contains("report.get(\"requestCount\")"));
        assert!(patched.contains("report.get(\"acknowledgedRequestNonces\")"));
        assert!(patched.contains("codexswitch_reload_auth_json_verified(&auth_path)"));
        assert!(patched.contains("if !manager_already_matches_handoff"));
        assert!(patched.contains("own_handoff.auth_generation"));
        assert!(!patched.contains("if !changed\n        || loaded_fingerprint"));
        assert!(!patched.contains("auth_manager.reload().await"));
        assert!(patched.contains("CODEXSWITCH_ROTATE_TIMEOUT_SECONDS"));
        assert!(!patched.contains("std::time::Duration::from_secs(10)"));
        assert_eq!(
            patched
                .matches("codexswitch_rotate_after_usage_limit(&sess, &turn_context).await")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("codexswitch_request_auth_generation,\n                        )\n                        .await")
                .count(),
            1
        );
        assert_eq!(
            patched
                .matches("codexswitch_rotate_after_auth_failure(&sess, &turn_context).await")
                .count(),
            1
        );
    }

    #[test]
    fn client_websocket_patch_matches_responses_metadata_reconnect_shape() {
        let temp_dir = tempfile::tempdir().unwrap();
        let client = temp_dir.path().join("client.rs");
        fs::write(
            &client,
            r#"
struct WebsocketSession {
    connection: Option<ApiWebSocketConnection>,
}

impl ModelClient {
    fn take_cached_websocket_session(&self) -> WebsocketSession {
        let mut cached_websocket_session = self
            .state
            .cached_websocket_session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        std::mem::take(&mut *cached_websocket_session)
    }
}

impl ModelClientSession {
    pub async fn preconnect_websocket(&mut self) -> std::result::Result<(), ApiError> {
        let client_setup = self.client.current_client_setup().await.map_err(|err| {
            ApiError::Stream(format!(
                "failed to build websocket prewarm client setup: {err}"
            ))
        })?;
        self.websocket_session.connection = Some(connection);
        self.websocket_session
            .set_connection_reused(/*connection_reused*/ false);
        Ok(())
    }

    async fn websocket_connection(&mut self) -> std::result::Result<&ApiWebSocketConnection, ApiError> {
        if needs_new {
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            self.websocket_session.last_response_from_untraced_warmup = false;
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    api_provider,
                    api_auth,
                    responses_metadata,
                    auth_context,
                    request_route_telemetry,
                )
                .await
            {
                Ok(new_conn) => new_conn,
                Err(err) => {
                    if matches!(err, ApiError::Transport(TransportError::Timeout)) {
                        self.reset_websocket_session();
                    }
                    return Err(err);
                }
            };
            self.websocket_session.connection = Some(new_conn);
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ false);
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }

        self.websocket_session
            .connection
            .as_ref()
            .ok_or(ApiError::Stream(
                "websocket connection is unavailable".to_string(),
            ))
    }
}
"#,
        )
        .unwrap();

        patch_client_websocket_source(&client).unwrap();

        let patched = fs::read_to_string(client).unwrap();
        assert!(patched.contains("Auth changed, opening new WebSocket with fresh credentials"));
        assert!(patched.contains("responses_metadata,"));
        assert!(patched.contains("fresh.api_auth.as_ref()"));
        assert!(patched.contains("fresh.agent_identity_telemetry.clone()"));
        assert!(patched.contains("self.websocket_session.auth_generation_at_creation = ag"));
    }
}
