/**
 * Kani nga bridge module kay tanging daan sa tanang frontend-to-C# calls.
 */
const REQUEST_TIMEOUT_MS = 30000;

const pendingRequests = new Map();
let requestCounter = 0;

/**
 * Kani nga listener kay nag-hanap sa response nga may matching requestId.
 */
window.chrome?.webview?.addEventListener('message', (event) => {
    const response = event.data;
    if (!response || typeof response.requestId === 'undefined') {
        return;
    }

    const pending = pendingRequests.get(response.requestId);
    if (!pending) {
        return;
    }

    clearTimeout(pending.timer);
    pendingRequests.delete(response.requestId);

    if (response.success) {
        pending.resolve(response.result);
    } else {
        pending.reject(new BridgeError(response.error || 'The operation failed.'));
    }
});

export class BridgeError extends Error {
    constructor(message) {
        super(message);
        this.name = 'BridgeError';
        this.isSafeMessage = true;
    }
}

/**
 * Kani nga method kay nag-send ug request sa C# bridge ug nagpaabot ug response.
 * @param {string} operation - Kani nga operation name kay rehistro ra sa C# side.
 * @param {object} payload - Kani nga payload kay mga inputs para sa operation.
 */
export function invoke(operation, payload = {}) {
    if (!window.chrome?.webview) {
        return Promise.reject(
            new BridgeError('The desktop bridge is not available in this environment.'));
    }

    const requestId = 'req-' + Date.now() + '-' + (++requestCounter);

    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            pendingRequests.delete(requestId);
            reject(new BridgeError(
                'The operation took too long to respond. Please try again.'));
        }, REQUEST_TIMEOUT_MS);

        pendingRequests.set(requestId, { resolve, reject, timer });

        window.chrome.webview.postMessage({
            requestId,
            operation,
            payload
        });
    });
}
