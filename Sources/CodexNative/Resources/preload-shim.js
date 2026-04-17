// CodexNative preload shim — replaces Electron's contextBridge
// Injected by WKWebView before the React app loads.
//
// The React frontend expects window.electronBridge with 13 methods.
// Core IPC (sendMessageFromView) is NOT needed here because the React
// app connects directly to the app-server via WebSocket. This shim
// only handles the UI-specific Electron APIs.

(function() {
    'use strict';

    // Session ID for this app launch
    const sessionId = crypto.randomUUID();

    // Shared state (replaces Electron's shared-object IPC)
    const sharedState = {};

    // Theme tracking
    let currentTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';

    // Pending call IDs for async Swift responses
    const pendingCalls = new Map();
    let nextCallId = 1;

    // Called by Swift to return results from async bridge calls
    window.__codexNativeBridgeReply = function(callId, result) {
        const resolve = pendingCalls.get(callId);
        if (resolve) {
            pendingCalls.delete(callId);
            resolve(result);
        }
    };

    // Called by Swift to deliver messages from the app-server or system
    window.__codexNativeDeliverMessage = function(message) {
        window.dispatchEvent(new MessageEvent('message', { data: message }));
    };

    // Helper: call Swift and wait for response
    function callSwift(method, params) {
        return new Promise((resolve) => {
            const callId = nextCallId++;
            pendingCalls.set(callId, resolve);
            window.webkit.messageHandlers.electronBridge.postMessage({
                method: method,
                callId: callId,
                ...params
            });
        });
    }

    // Helper: fire-and-forget to Swift
    function notifySwift(method, params) {
        try {
            window.webkit.messageHandlers.electronBridge.postMessage({
                method: method,
                ...params
            });
        } catch (e) {
            console.warn('[CodexNative] Bridge notify failed:', method, e);
        }
    }

    // The bridge object — matches Electron's preload.js API surface exactly
    const bridge = {
        // === Core IPC ===
        // sendMessageFromView: The React app uses this for Electron IPC.
        // In CodexNative, the React frontend connects to the app-server
        // directly via WebSocket (same as VS Code extension mode).
        // We still need to handle non-WebSocket messages (shared-object-set, log-message).
        sendMessageFromView: async (msg) => {
            if (msg.type === 'shared-object-set') {
                sharedState[msg.key] = msg.value;
                return;
            }
            if (msg.type === 'log-message') {
                // Route logs to Swift for native logging
                notifySwift('log', { level: msg.level, message: msg.message });
                return;
            }
            // Forward other messages to Swift
            notifySwift('sendMessageFromView', { payload: msg });
        },

        sendWorkerMessageFromView: async (workerId, msg) => {
            notifySwift('sendWorkerMessageFromView', { workerId, payload: msg });
        },

        subscribeToWorkerMessages: (workerId, callback) => {
            const handler = (event) => {
                const data = event.data;
                if (data && data.__workerMessage && data.workerId === workerId) {
                    callback(data.payload);
                }
            };
            window.addEventListener('message', handler);
            return () => window.removeEventListener('message', handler);
        },

        // === UI APIs ===
        showContextMenu: async (items) => {
            return callSwift('showContextMenu', { items });
        },

        showApplicationMenu: async (menuId, x, y) => {
            notifySwift('showApplicationMenu', { menuId, x, y });
        },

        getPathForFile: (file) => {
            // WKWebView doesn't expose full file paths for security.
            // Return the filename — drag-drop file access is handled separately.
            return file.name || null;
        },

        // === Theme ===
        getSystemThemeVariant: () => currentTheme,

        subscribeToSystemThemeVariant: (callback) => {
            const mq = window.matchMedia('(prefers-color-scheme: dark)');
            const handler = (e) => {
                currentTheme = e.matches ? 'dark' : 'light';
                callback();
            };
            mq.addEventListener('change', handler);
            return () => mq.removeEventListener('change', handler);
        },

        // === State ===
        getSharedObjectSnapshotValue: (key) => sharedState[key],

        // === Diagnostics ===
        getSentryInitOptions: () => ({
            disabled: true,
            codexAppSessionId: sessionId
        }),
        getAppSessionId: () => sessionId,
        getBuildFlavor: () => 'prod',
        getFastModeRolloutMetrics: async () => ({}),
        triggerSentryTestError: async () => {},
    };

    // Expose to the React app — same names as Electron's contextBridge
    window.codexWindowType = 'electron';
    window.electronBridge = bridge;

    // Log unknown method calls for debugging
    window.electronBridge = new Proxy(bridge, {
        get(target, prop) {
            if (prop in target) return target[prop];
            console.warn(`[CodexNative] Unknown electronBridge method: ${String(prop)}`);
            return (...args) => {
                console.warn(`[CodexNative] Called unknown method: ${String(prop)}`, args);
                return Promise.resolve(undefined);
            };
        }
    });

    console.log('[CodexNative] Preload shim loaded, session:', sessionId);
})();
