/**
 * Kani nga state module kay nagdala sa frontend session state.
 * Kini nga state kay para sa UI ra; ang permissions gi-enforce gihapon sa C#.
 */
let currentUser = null;
let permissions = new Set();

export function getUser() {
    return currentUser;
}

export function isLoggedIn() {
    return currentUser !== null;
}

export function hasPermission(code) {
    return permissions.has(code);
}

export function setSession(user, permissionList) {
    // Kani nga method kay para sa frontend UI state lang dili security.
    currentUser = user;
    permissions = new Set(permissionList || []);
}

export function clearSession() {
    currentUser = null;
    permissions = new Set();
}
