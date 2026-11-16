/**
 * Kani nga users page module kay para sa user accounts ug roles management.
 * Ang tanang operations mo-agi sa C# bridge nga may backend permission checks.
 */
import { invoke } from '../../assets/js/core/bridge.js';
import { hasPermission } from '../../assets/js/core/state.js';
import { showToast } from '../../assets/js/components/toast.js';

let usersData = [];
let rolesData = [];
let permissionsData = [];
let searchHandler = null;
let resetTargetUserID = null;
let selectedRoleID = null;

// Kani nga state kay para sa pending Activate/Deactivate confirmation.
let pendingStatusUser = null;
let pendingStatusTarget = false;

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa data.
 */
export async function init(root) {
    applyPermissionGating(root);

    root.querySelector('#btnOpenAddUser')?.addEventListener('click', () => {
        openUserModal(root, null);
    });

    root.querySelector('#btnNewRole')?.addEventListener('click', () => {
        openRoleModal(root, null);
    });

    searchHandler = () => renderUsersTable(root);
    root.querySelector('#userSearch')?.addEventListener('input', searchHandler);

    wireModalClosers(root);
    wireUserForm(root);
    wireResetForm(root);
    wireRoleForm(root);
    wireUserStatusModal(root);

    await reloadAll(root);
}

/**
 * Kani nga reload kay nagkuha sa users ug roles gikan sa backend.
 */
async function reloadAll(root) {
    try {
        const [usersPayload, rolesPayload] = await Promise.all([
            invoke('UsersList'),
            invoke('RolesList')
        ]);

        usersData = usersPayload.users || [];
        rolesData = rolesPayload.roles || [];
        permissionsData = rolesPayload.permissions || [];

        renderUsersTable(root);
        renderRolesTable(root);
        fillRoleSelect(root);
        renderPermissionsGrid(root);
    } catch (error) {
        showToast('error', error.message || 'The user management data could not be loaded.');

        const usersBody = root.querySelector('#usersTableBody');
        if (usersBody) {
            usersBody.innerHTML =
                '<tr><td colspan="8" class="data-table__empty">' +
                'The user accounts could not be loaded.</td></tr>';
        }

        const rolesBody = root.querySelector('#rolesTableBody');
        if (rolesBody) {
            rolesBody.innerHTML =
                '<tr><td colspan="6" class="data-table__empty">' +
                'The roles could not be loaded.</td></tr>';
        }
    }
}

/**
 * Kani nga gating kay nagdili sa buttons nga walay permission.
 */
function applyPermissionGating(root) {
    root.querySelectorAll('[data-requires]').forEach((button) => {
        if (!hasPermission(button.dataset.requires)) {
            button.disabled = true;
            button.title = 'You do not have permission to use this action.';
        }
    });
}

/**
 * Kani nga render kay nag-filter sa users table base sa search.
 */
function renderUsersTable(root) {
    const body = root.querySelector('#usersTableBody');

    if (!body) {
        return;
    }

    const searchTerm = (
        root.querySelector('#userSearch')?.value || ''
    ).trim().toLowerCase();

    const filtered = usersData.filter((user) => {
        if (!searchTerm) {
            return true;
        }

        const haystack = [
            user.UserID,
            user.FirstName,
            user.MiddleName,
            user.LastName,
            user.Username,
            user.Email,
            user.RoleName,
            user.IsActive ? 'active' : 'inactive'
        ].join(' ').toLowerCase();

        return haystack.includes(searchTerm);
    });

    if (filtered.length === 0) {
        body.innerHTML =
            '<tr><td colspan="8" class="data-table__empty">' +
            'No user accounts found.</td></tr>';
        return;
    }

    body.innerHTML = '';

    filtered.forEach((user) => {
        body.appendChild(buildUserRow(root, user));
    });
}

/**
 * Kani nga row builder kay nag-himo sa table row sa usa ka user.
 */
function buildUserRow(root, user) {
    const row = document.createElement('tr');

    const idCell = document.createElement('td');
    idCell.textContent = String(user.UserID ?? '');
    row.appendChild(idCell);

    const nameCell = document.createElement('td');
    nameCell.textContent = formatFullName(user);
    row.appendChild(nameCell);

    const usernameCell = document.createElement('td');
    usernameCell.textContent = user.Username || '\u2014';
    row.appendChild(usernameCell);

    const emailCell = document.createElement('td');
    emailCell.textContent = user.Email || '\u2014';
    row.appendChild(emailCell);

    const roleCell = document.createElement('td');
    const roleBadge = document.createElement('span');
    roleBadge.className = 'badge badge--info';
    roleBadge.textContent = user.RoleName || '\u2014';
    roleCell.appendChild(roleBadge);
    row.appendChild(roleCell);

    const statusCell = document.createElement('td');
    const statusBadge = document.createElement('span');
    statusBadge.className = user.IsActive
        ? 'badge badge--success'
        : 'badge badge--error';
    statusBadge.textContent = user.IsActive ? 'Active' : 'Inactive';
    statusCell.appendChild(statusBadge);
    row.appendChild(statusCell);

    const lastLoginCell = document.createElement('td');
    lastLoginCell.textContent = formatDate(user.LastLogin);
    row.appendChild(lastLoginCell);

    const actionsCell = document.createElement('td');
    const actionsContainer = document.createElement('div');
    actionsContainer.className = 'user-row-actions';

    const canUpdate = hasPermission('users.update');
    const canDeactivate = hasPermission('users.deactivate');

    if (canUpdate) {
        // Kani nga button kay para sa pag-edit sa user account.
        const editButton = document.createElement('button');
        editButton.type = 'button';
        editButton.className = 'btn-action btn-action--grey';
        editButton.textContent = 'Edit';
        editButton.addEventListener('click', () => {
            openUserModal(root, user);
        });
        actionsContainer.appendChild(editButton);

        // Kani nga button kay para sa admin password reset.
        const resetButton = document.createElement('button');
        resetButton.type = 'button';
        resetButton.className = 'btn-action btn-action--grey';
        resetButton.textContent = 'Reset Password';
        resetButton.addEventListener('click', () => {
            openResetModal(root, user);
        });
        actionsContainer.appendChild(resetButton);
    }

    if (canDeactivate && user.UserID !== undefined && user.UserID !== null) {
        // Kani nga button kay mo-toggle sa status ug mo-open sa confirmation modal.
        const statusButton = document.createElement('button');
        statusButton.type = 'button';
        statusButton.className = 'btn-action ' +
            (user.IsActive ? 'btn-action--danger' : 'btn-action--success');
        statusButton.textContent = user.IsActive ? 'Deactivate' : 'Activate';
        statusButton.addEventListener('click', () => {
            openUserStatusModal(root, user, !user.IsActive);
        });
        actionsContainer.appendChild(statusButton);
    }

    if (actionsContainer.children.length === 0) {
        actionsCell.textContent = '\u2014';
    } else {
        actionsCell.appendChild(actionsContainer);
    }

    row.appendChild(actionsCell);

    return row;
}

/**
 * Kani nga modal kay para sa confirmation sa Activate/Deactivate user account.
 */
function openUserStatusModal(root, user, targetActive) {
    pendingStatusUser = user;
    pendingStatusTarget = targetActive;

    const modal = root.querySelector('#userStatusModal');
    const confirmButton = root.querySelector('#btnConfirmUserStatus');
    const fullName = formatFullName(user);

    root.querySelector('#userStatusModalTitle').textContent =
        targetActive ? 'Activate User' : 'Deactivate User';

    root.querySelector('#userStatusModalMessage').textContent = targetActive
        ? 'Activate the account of "' + fullName +
        '"? The user will be able to sign in and access the system again.'
        : 'Deactivate the account of "' + fullName +
        '"? The user will no longer be able to sign in.';

    confirmButton.textContent = targetActive ? 'Activate' : 'Deactivate';
    confirmButton.className = 'btn user-status-confirm ' +
        (targetActive ? 'btn--primary' : 'btn--danger');
    confirmButton.disabled = false;

    modal.classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa status confirmation modal.
 */
function wireUserStatusModal(root) {
    const modal = root.querySelector('#userStatusModal');
    const confirmButton = root.querySelector('#btnConfirmUserStatus');

    const closeModal = () => {
        pendingStatusUser = null;
        pendingStatusTarget = false;
        modal.classList.add('u-hidden');
        confirmButton.disabled = false;
    };

    root.querySelector('#btnCloseUserStatusModal')?.addEventListener(
        'click', closeModal
    );

    root.querySelector('#btnCancelUserStatus')?.addEventListener(
        'click', closeModal
    );

    modal?.addEventListener('click', (event) => {
        if (event.target === modal && !confirmButton.disabled) {
            closeModal();
        }
    });

    // Kani nga confirm kay mo-update sa account status human sa user approval.
    confirmButton?.addEventListener('click', async () => {
        if (!pendingStatusUser || confirmButton.disabled) {
            return;
        }

        const user = pendingStatusUser;
        const targetActive = pendingStatusTarget;

        confirmButton.disabled = true;

        try {
            await invoke('UserSetActive', {
                targetUserID: String(user.UserID),
                isActive: targetActive ? 'true' : 'false'
            });

            showToast(
                'success',
                'The account of ' + formatFullName(user) + ' has been ' +
                (targetActive ? 'activated.' : 'deactivated.')
            );

            closeModal();
            await reloadAll(root);
        } catch (error) {
            showToast(
                'error',
                error.message || 'The account status could not be updated.'
            );

            confirmButton.disabled = false;
        }
    });
}

/**
 * Kani nga render kay nag-display sa roles table.
 */
function renderRolesTable(root) {
    const body = root.querySelector('#rolesTableBody');

    if (!body) {
        return;
    }

    body.innerHTML = '';

    if (rolesData.length === 0) {
        body.innerHTML =
            '<tr><td colspan="6" class="data-table__empty">' +
            'No roles found.</td></tr>';
        return;
    }

    rolesData.forEach((role) => {
        const row = document.createElement('tr');

        const nameCell = document.createElement('td');
        nameCell.textContent = role.RoleName || '\u2014';
        row.appendChild(nameCell);

        const descriptionCell = document.createElement('td');
        descriptionCell.textContent = role.Description || '\u2014';
        row.appendChild(descriptionCell);

        const permissionCell = document.createElement('td');
        permissionCell.textContent =
            String((role.PermissionCodes || []).length) + ' permission(s)';
        row.appendChild(permissionCell);

        const activeUsersCell = document.createElement('td');
        activeUsersCell.textContent = String(role.ActiveUserCount ?? 0);
        row.appendChild(activeUsersCell);

        const statusCell = document.createElement('td');
        const statusBadge = document.createElement('span');
        statusBadge.className = role.IsActive
            ? 'badge badge--success'
            : 'badge badge--error';
        statusBadge.textContent = role.IsActive ? 'Active' : 'Disabled';
        statusCell.appendChild(statusBadge);
        row.appendChild(statusCell);

        const actionsCell = document.createElement('td');

        if (hasPermission('settings.manage')) {
            const editButton = document.createElement('button');
            editButton.type = 'button';
            editButton.className = 'btn-action btn-action--grey';
            editButton.textContent = 'Edit';
            editButton.addEventListener('click', () => {
                openRoleModal(root, role);
            });
            actionsCell.appendChild(editButton);
        } else {
            actionsCell.textContent = '\u2014';
        }

        row.appendChild(actionsCell);
        body.appendChild(row);
    });
}

/**
 * Kani nga helper kay nagpuno sa role dropdown sa user modal.
 */
function fillRoleSelect(root) {
    const select = root.querySelector('#selRole');

    if (!select) {
        return;
    }

    select.innerHTML = '';

    const availableRoles = rolesData.filter((role) => {
        return role.IsActive || String(role.RoleID) === String(selectedRoleID);
    });

    availableRoles.forEach((role) => {
        const option = document.createElement('option');
        option.value = String(role.RoleID);
        option.textContent = role.RoleName;
        select.appendChild(option);
    });

    if (selectedRoleID !== null) {
        select.value = String(selectedRoleID);
    }
}

/**
 * Kani nga render kay nagpuno sa permission checkboxes sa role modal.
 */
function renderPermissionsGrid(root) {
    const grid = root.querySelector('#permissionsGrid');

    if (!grid) {
        return;
    }

    grid.innerHTML = '';

    permissionsData.forEach((permission) => {
        const label = document.createElement('label');
        label.className = 'permissions-grid__item';

        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.value = permission.PermissionCode;

        const text = document.createElement('span');

        const code = document.createElement('span');
        code.className = 'permissions-grid__code';
        code.textContent = permission.PermissionCode;

        const hint = document.createElement('span');
        hint.className = 'permissions-grid__hint';
        hint.textContent = permission.Description || '';

        text.appendChild(code);
        text.appendChild(hint);
        label.appendChild(checkbox);
        label.appendChild(text);
        grid.appendChild(label);
    });
}

/**
 * Kani nga modal kay para sa paghimo o pag-edit sa user account.
 */
function openUserModal(root, user) {
    const modal = root.querySelector('#userModal');
    const title = root.querySelector('#userModalTitle');
    const passwordField = root.querySelector('#fieldPassword');
    const usernameField = root.querySelector('#fieldUsername');

    root.querySelector('#editUserID').value =
        user ? String(user.UserID) : '';

    root.querySelector('#txtFirstName').value =
        user ? user.FirstName || '' : '';

    root.querySelector('#txtLastName').value =
        user ? user.LastName || '' : '';

    root.querySelector('#txtMiddleName').value =
        user ? user.MiddleName || '' : '';

    root.querySelector('#txtUsername').value =
        user ? user.Username || '' : '';

    root.querySelector('#txtPassword').value = '';

    root.querySelector('#txtEmail').value =
        user ? user.Email || '' : '';

    selectedRoleID = user ? user.RoleID : null;

    fillRoleSelect(root);

    if (user) {
        root.querySelector('#selRole').value = String(user.RoleID);
    }

    title.textContent = user ? 'Edit User Account' : 'New User Account';

    usernameField.style.display = user ? 'none' : '';
    passwordField.style.display = user ? 'none' : '';

    root.querySelector('#errorPassword').textContent = '';

    modal.classList.remove('u-hidden');
}

/**
 * Kani nga modal kay para sa admin password reset.
 */
function openResetModal(root, user) {
    resetTargetUserID = user.UserID;

    root.querySelector('#resetUserInfo').textContent =
        'Resetting the password of ' +
        formatFullName(user) + ' (' + user.Username + ').';

    root.querySelector('#txtNewPassword').value = '';
    root.querySelector('#errorNewPassword').textContent = '';
    root.querySelector('#resetModal').classList.remove('u-hidden');
}

/**
 * Kani nga modal kay para sa paghimo o pag-edit sa role.
 */
function openRoleModal(root, role) {
    const modal = root.querySelector('#roleModal');

    root.querySelector('#editRoleID').value =
        role ? String(role.RoleID) : '';

    root.querySelector('#txtRoleName').value =
        role ? role.RoleName || '' : '';

    root.querySelector('#txtRoleDescription').value =
        role ? role.Description || '' : '';

    // Kani nga guard kay nagpanalipod sa built-in Admin role.
    const isAdminRole = role && Number(role.RoleID) === 1;

    root.querySelector('#fieldRoleActive').style.display =
        isAdminRole ? 'none' : '';

    root.querySelector('#chkRoleActive').checked =
        role ? Boolean(role.IsActive) : true;

    const assignedCodes = new Set(
        role ? role.PermissionCodes || [] : []
    );

    root.querySelectorAll('#permissionsGrid input[type="checkbox"]')
        .forEach((checkbox) => {
            checkbox.checked = assignedCodes.has(checkbox.value);
            checkbox.disabled = Boolean(isAdminRole);
        });

    root.querySelector('#roleModalTitle').textContent =
        role ? 'Edit Role: ' + role.RoleName : 'New Role';

    modal.classList.remove('u-hidden');
}

/**
 * Kani nga wiring kay para sa tanang modal close buttons ug overlay clicks.
 */
function wireModalClosers(root) {
    const closeMap = [
        ['#btnCloseUserModal', '#userModal'],
        ['#btnCancelUser', '#userModal'],
        ['#btnCloseResetModal', '#resetModal'],
        ['#btnCancelReset', '#resetModal'],
        ['#btnCloseRoleModal', '#roleModal'],
        ['#btnCancelRole', '#roleModal']
    ];

    closeMap.forEach(([buttonSelector, modalSelector]) => {
        root.querySelector(buttonSelector)?.addEventListener('click', () => {
            root.querySelector(modalSelector)?.classList.add('u-hidden');
        });
    });

    ['#userModal', '#resetModal', '#roleModal'].forEach((selector) => {
        const modal = root.querySelector(selector);

        modal?.addEventListener('click', (event) => {
            if (event.target === modal) {
                modal.classList.add('u-hidden');
            }
        });
    });
}

/**
 * Kani nga submit kay nagdala sa create o update sa user account.
 */
function wireUserForm(root) {
    root.querySelector('#userForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const editUserID = root.querySelector('#editUserID').value;
        const isEdit = editUserID !== '';
        const saveButton = root.querySelector('#btnSaveUser');

        const payload = {
            firstName: root.querySelector('#txtFirstName').value.trim(),
            lastName: root.querySelector('#txtLastName').value.trim(),
            middleName: root.querySelector('#txtMiddleName').value.trim(),
            email: root.querySelector('#txtEmail').value.trim(),
            roleID: root.querySelector('#selRole').value
        };

        if (!isEdit) {
            payload.username = root.querySelector('#txtUsername').value.trim();
            payload.password = root.querySelector('#txtPassword').value;
        }

        // Kani nga checks kay para sa initial client-side validation.
        if (!payload.firstName || !payload.lastName ||
            !payload.email || !payload.roleID) {
            showToast('warning', 'Please fill in all required fields.');
            return;
        }

        if (!isEdit && !payload.username) {
            showToast('warning', 'Please enter a username.');
            return;
        }

        if (!isEdit && !payload.password) {
            showToast('warning', 'Please enter an initial password.');
            return;
        }

        saveButton.disabled = true;

        try {
            if (isEdit) {
                payload.targetUserID = editUserID;
                await invoke('UserUpdate', payload);
                showToast('success', 'The user account has been updated.');
            } else {
                await invoke('UserCreate', payload);
                showToast(
                    'success',
                    'The user account has been created. Share the temporary password securely.'
                );
            }

            root.querySelector('#userModal').classList.add('u-hidden');
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message || 'The user account could not be saved.');
        } finally {
            saveButton.disabled = false;
        }
    });
}

/**
 * Kani nga submit kay nagdala sa admin password reset.
 */
function wireResetForm(root) {
    root.querySelector('#resetForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const newPassword = root.querySelector('#txtNewPassword').value;
        const errorLabel = root.querySelector('#errorNewPassword');
        const submitButton = root.querySelector('#resetForm button[type="submit"]');

        errorLabel.textContent = '';

        // Kani nga policy kay para sa minimum password requirements.
        const policy = /^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[^a-zA-Z0-9]).{8,}$/;

        if (!policy.test(newPassword)) {
            errorLabel.textContent =
                'Password must contain an uppercase letter, a lowercase letter, a number, and a special character.';
            return;
        }

        if (resetTargetUserID === null || resetTargetUserID === undefined) {
            showToast('error', 'No user account was selected.');
            return;
        }

        submitButton.disabled = true;

        try {
            await invoke('UserResetPassword', {
                targetUserID: String(resetTargetUserID),
                newPassword
            });

            showToast('success', 'The password has been reset.');
            root.querySelector('#resetModal').classList.add('u-hidden');
        } catch (error) {
            showToast('error', error.message || 'The password could not be reset.');
        } finally {
            submitButton.disabled = false;
        }
    });
}

/**
 * Kani nga submit kay nagdala sa create o update sa role.
 */
function wireRoleForm(root) {
    root.querySelector('#roleForm')?.addEventListener('submit', async (event) => {
        event.preventDefault();

        const editRoleID = root.querySelector('#editRoleID').value;

        const selectedCodes = Array.from(
            root.querySelectorAll('#permissionsGrid input[type="checkbox"]:checked')
        ).map((checkbox) => checkbox.value);

        if (selectedCodes.length === 0) {
            showToast('warning', 'Please select at least one permission.');
            return;
        }

        const payload = {
            roleName: root.querySelector('#txtRoleName').value.trim(),
            description: root.querySelector('#txtRoleDescription').value.trim(),
            isActive: root.querySelector('#chkRoleActive').checked ? 'true' : 'false',
            permissionCodes: selectedCodes
        };

        if (!payload.roleName) {
            showToast('warning', 'Please enter a role name.');
            return;
        }

        const submitButton = root.querySelector('#roleForm button[type="submit"]');
        submitButton.disabled = true;

        try {
            if (editRoleID !== '') {
                payload.roleID = editRoleID;
                await invoke('RoleSave', payload);
                showToast('success', 'The role has been updated.');
            } else {
                await invoke('RoleSave', payload);
                showToast('success', 'The role has been created.');
            }

            root.querySelector('#roleModal').classList.add('u-hidden');
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message || 'The role could not be saved.');
        } finally {
            submitButton.disabled = false;
        }
    });
}

/**
 * Kani nga helper kay nag-format sa full name sa user.
 */
function formatFullName(user) {
    const firstName = user.FirstName || '';
    const middleName = user.MiddleName
        ? ' ' + user.MiddleName.charAt(0).toUpperCase() + '.'
        : '';
    const lastName = user.LastName || '';

    return (firstName + middleName + ' ' + lastName).trim();
}

/**
 * Kani nga helper kay para sa safe HTML text kung kinahanglan.
 */
function escapeHtml(value) {
    return String(value == null ? '' : value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Kani nga helper kay nag-format sa date gikan sa backend.
 */
function formatDate(value) {
    // Kani nga parser kay nag-handle sa .NET JSON date format.
    if (!value) {
        return '\u2014';
    }

    const match = /\/Date\((-?\d+)\)\//.exec(value);
    const ticks = match ? Number(match[1]) : NaN;
    const date = isNaN(ticks) ? new Date(value) : new Date(ticks);

    if (isNaN(date.getTime())) {
        return '\u2014';
    }

    return date.toLocaleDateString() + ' ' +
        date.toLocaleTimeString([], {
            hour: '2-digit',
            minute: '2-digit'
        });
}

/**
 * Kani nga destroy kay para malimpyohan ang module state.
 */
export function destroy() {
    searchHandler = null;
    usersData = [];
    rolesData = [];
    permissionsData = [];
    resetTargetUserID = null;
    selectedRoleID = null;
    pendingStatusUser = null;
    pendingStatusTarget = false;
}
