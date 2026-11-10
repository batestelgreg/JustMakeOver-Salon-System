/**
 * Kani nga events module kay simple nga publish-subscribe para sa shared app events.
 */
const listeners = new Map();

export function subscribe(eventName, handler) {
    if (!listeners.has(eventName)) {
        listeners.set(eventName, new Set());
    }

    listeners.get(eventName).add(handler);
    return () => unsubscribe(eventName, handler);
}

export function unsubscribe(eventName, handler) {
    listeners.get(eventName)?.delete(handler);
}

export function publish(eventName, detail) {
    // Kani nga publish kay mo-notify sa tanang subscribers sa event.
    listeners.get(eventName)?.forEach((handler) => {
        try {
            handler(detail);
        } catch (error) {
            console.error('Event handler failed for ' + eventName, error);
        }
    });
}

export const AppEvents = Object.freeze({
    SessionChanged: 'session:changed',
    Navigate: 'app:navigate',
    LoginSucceeded: 'auth:login-succeeded',
    LogoutRequested: 'auth:logout-requested'
});
