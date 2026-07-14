fn patch_client_websocket_source(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    patch_file_after(
        path,
        "    connection: Option<ApiWebSocketConnection>,",
        r#"
    /// Auth generation that produced this cached connection.
    /// If auth_generation changes after SIGHUP, the connection must be reopened.
    auth_generation_at_creation: u64,"#,
        "auth_generation_at_creation",
    )?;
    patch_all(
        path,
        r#"    fn take_cached_websocket_session(&self) -> WebsocketSession {
        let mut cached_websocket_session = self
            .state
            .cached_websocket_session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        std::mem::take(&mut *cached_websocket_session)
    }"#,
        r#"    fn take_cached_websocket_session(&self) -> WebsocketSession {
        let mut cached_websocket_session = self
            .state
            .cached_websocket_session
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let cached = std::mem::take(&mut *cached_websocket_session);
        if let Some(auth_manager) = self.state.provider.auth_manager() {
            let current_gen = auth_manager.auth_generation();
            if cached.auth_generation_at_creation != current_gen && cached.connection.is_some() {
                tracing::info!(
                    "Auth generation changed ({} -> {}), discarding cached WebSocket",
                    cached.auth_generation_at_creation,
                    current_gen
                );
                return WebsocketSession {
                    auth_generation_at_creation: current_gen,
                    ..WebsocketSession::default()
                };
            }
        }
        cached
    }"#,
    )?;
    patch_file_after(
        path,
        r#"        let client_setup = self.client.current_client_setup().await.map_err(|err| {
            ApiError::Stream(format!(
                "failed to build websocket prewarm client setup: {err}"
            ))
        })?;"#,
        r#"
        let generation_at_resolve = self
            .client
            .state
            .provider
            .auth_manager()
            .as_ref()
            .map(|am| am.auth_generation());"#,
        "generation_at_resolve",
    )?;
    patch_all(
        path,
        r#"        self.websocket_session.connection = Some(connection);
        self.websocket_session
            .set_connection_reused(/*connection_reused*/ false);
        Ok(())"#,
        r#"        self.websocket_session.connection = Some(connection);
        self.websocket_session
            .set_connection_reused(/*connection_reused*/ false);
        if let Some(auth_gen) = generation_at_resolve {
            self.websocket_session.auth_generation_at_creation = auth_gen;
        }
        Ok(())"#,
    )?;
    let mut websocket_reconnect_patched = false;
    websocket_reconnect_patched |= patch_all(
        path,
        r#"        if needs_new {
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    api_provider,
                    api_auth,
                    Some(turn_state),
                    turn_metadata_header,
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
        }"#,
        r#"        let current_auth_gen = self
            .client
            .state
            .provider
            .auth_manager()
            .as_ref()
            .map(|am| am.auth_generation());
        let auth_changed = current_auth_gen
            .is_some_and(|ag| ag != self.websocket_session.auth_generation_at_creation);

        if needs_new || auth_changed {
            if auth_changed {
                tracing::info!("Auth changed, opening new WebSocket with fresh credentials");
            }
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let (use_provider, use_auth, use_gen, use_auth_context) = if auth_changed {
                let fresh = self.client.current_client_setup().await.map_err(|err| {
                    ApiError::Stream(format!(
                        "failed to re-resolve auth after SIGHUP: {err}"
                    ))
                })?;
                let fresh_gen = self
                    .client
                    .state
                    .provider
                    .auth_manager()
                    .as_ref()
                    .map(|am| am.auth_generation());
                let fresh_auth_context = AuthRequestTelemetryContext::new(
                    fresh.auth.as_ref().map(CodexAuth::auth_mode),
                    fresh.api_auth.as_ref(),
                    fresh.agent_identity_telemetry.clone(),
                    PendingUnauthorizedRetry::default(),
                );
                (fresh.api_provider, fresh.api_auth, fresh_gen, fresh_auth_context)
            } else {
                (api_provider, api_auth, current_auth_gen, auth_context)
            };
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    use_provider,
                    use_auth,
                    Some(turn_state),
                    turn_metadata_header,
                    use_auth_context,
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
            if let Some(ag) = use_gen {
                self.websocket_session.auth_generation_at_creation = ag;
            }
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }"#,
    )?;
    websocket_reconnect_patched |= patch_all(
        path,
        r#"        if needs_new {
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            self.websocket_session.last_response_from_untraced_warmup = false;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    api_provider,
                    api_auth,
                    Some(turn_state),
                    turn_metadata_header,
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
        }"#,
        r#"        let current_auth_gen = self
            .client
            .state
            .provider
            .auth_manager()
            .as_ref()
            .map(|am| am.auth_generation());
        let auth_changed = current_auth_gen
            .is_some_and(|ag| ag != self.websocket_session.auth_generation_at_creation);

        if needs_new || auth_changed {
            if auth_changed {
                tracing::info!("Auth changed, opening new WebSocket with fresh credentials");
            }
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            self.websocket_session.last_response_from_untraced_warmup = false;
            let turn_state = options
                .turn_state
                .clone()
                .unwrap_or_else(|| Arc::clone(&self.turn_state));
            let (use_provider, use_auth, use_gen, use_auth_context) = if auth_changed {
                let fresh = self.client.current_client_setup().await.map_err(|err| {
                    ApiError::Stream(format!(
                        "failed to re-resolve auth after SIGHUP: {err}"
                    ))
                })?;
                let fresh_gen = self
                    .client
                    .state
                    .provider
                    .auth_manager()
                    .as_ref()
                    .map(|am| am.auth_generation());
                let fresh_auth_context = AuthRequestTelemetryContext::new(
                    fresh.auth.as_ref().map(CodexAuth::auth_mode),
                    fresh.api_auth.as_ref(),
                    fresh.agent_identity_telemetry.clone(),
                    PendingUnauthorizedRetry::default(),
                );
                (fresh.api_provider, fresh.api_auth, fresh_gen, fresh_auth_context)
            } else {
                (api_provider, api_auth, current_auth_gen, auth_context)
            };
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    use_provider,
                    use_auth,
                    Some(turn_state),
                    turn_metadata_header,
                    use_auth_context,
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
            if let Some(ag) = use_gen {
                self.websocket_session.auth_generation_at_creation = ag;
            }
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }"#,
    )?;
    websocket_reconnect_patched |= patch_all(
        path,
        r#"        if needs_new {
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
        }"#,
        r#"        let current_auth_gen = self
            .client
            .state
            .provider
            .auth_manager()
            .as_ref()
            .map(|am| am.auth_generation());
        let auth_changed = current_auth_gen
            .is_some_and(|ag| ag != self.websocket_session.auth_generation_at_creation);

        if needs_new || auth_changed {
            if auth_changed {
                tracing::info!("Auth changed, opening new WebSocket with fresh credentials");
            }
            self.websocket_session.last_request = None;
            self.websocket_session.last_response_rx = None;
            self.websocket_session.last_response_from_untraced_warmup = false;
            let (use_provider, use_auth, use_gen, use_auth_context) = if auth_changed {
                let fresh = self.client.current_client_setup().await.map_err(|err| {
                    ApiError::Stream(format!(
                        "failed to re-resolve auth after SIGHUP: {err}"
                    ))
                })?;
                let fresh_gen = self
                    .client
                    .state
                    .provider
                    .auth_manager()
                    .as_ref()
                    .map(|am| am.auth_generation());
                let fresh_auth_context = AuthRequestTelemetryContext::new(
                    fresh.auth.as_ref().map(CodexAuth::auth_mode),
                    fresh.api_auth.as_ref(),
                    fresh.agent_identity_telemetry.clone(),
                    PendingUnauthorizedRetry::default(),
                );
                (fresh.api_provider, fresh.api_auth, fresh_gen, fresh_auth_context)
            } else {
                (api_provider, api_auth, current_auth_gen, auth_context)
            };
            let new_conn = match self
                .client
                .connect_websocket(
                    session_telemetry,
                    use_provider,
                    use_auth,
                    responses_metadata,
                    use_auth_context,
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
            if let Some(ag) = use_gen {
                self.websocket_session.auth_generation_at_creation = ag;
            }
        } else {
            self.websocket_session
                .set_connection_reused(/*connection_reused*/ true);
        }"#,
    )?;
    let patched_content =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    if !websocket_reconnect_patched
        && !patched_content.contains("Auth changed, opening new WebSocket with fresh credentials")
    {
        bail!(
            "Codex WebSocket reconnect patch did not match {}",
            path.display()
        );
    }
    Ok(())
}
