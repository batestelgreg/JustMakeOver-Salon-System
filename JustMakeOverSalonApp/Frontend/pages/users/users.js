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

/**
 * Kani nga init kay nag-wire sa mga buttons ug nag-load sa data.
 */
export async function init(root) {
    // Kani nga permission gating kay para makita ra ang mga buttons nga allowed sa user.
    applyPermissionGating(root);

    root.querySelector('#btnOpenAddUser')?.addEventListener('click', () => openUserModal(root, null));
    root.querySelector('#btnNewRole')?.addEventListener('click', () => openRoleModal(root, null));

    searchHandler = () => renderUsersTable(root);
    root.querySelector('#userSearch')?.addEventListener('input', searchHandler);

    wireModalClosers(root);
    wireUserForm(root);
    wireResetForm(root);
    wireRoleForm(root);

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
        showToast('error', error.message);
        const body = root.querySelector('#usersTableBody');
        if (body) {
            body.innerHTML = '<tr><td colspan="8" class="data-table__empty">' +
                'The user accounts could not be loaded.</td></tr>';
        }
    }
}

/**
 * Kani nga gating kay nagdili sa mga buttons nga wala sa permission sa user.
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
 * Kani nga render kay nagdibu-on sa users table base sa search filter.
 */
function renderUsersTable(root) {
    const body = root.querySelector('#usersTableBody');
    if (!body) {
        return;
    }

    const searchTerm = (root.querySelector('#userSearch')?.value || '').trim().toLowerCase();
    const filtered = usersData.filter((user) => {
        if (!searchTerm) {
            return true;
        }

        const haystack = [
            user.FirstName, user.LastName, user.Username, user.Email, user.RoleName
        ].join(' ').toLowerCase();
        return haystack.includes(searchTerm);
    });

    if (filtered.length === 0) {
        body.innerHTML = '<tr><td colspan="8" class="data-table__empty">No user accounts found.</td></tr>';
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

    const nameCell = document.createElement('td');
    nameCell.textContent = formatFullName(user);

    const statusBadge = user.IsActive
        ? '<span class="badge badge--success">Active</span>'
        : '<span class="badge badge--error">Inactive</span>';

    const canUpdate = hasPermission('users.update');
    const canDeactivate = hasPermission('users.deactivate');

    row.innerHTML = [
        '<td>' + user.UserID + '</td>',
        nameCell.outerHTML,
        '<td>' + escapeHtml(user.Username) + '</td>',
        '<td>' + escapeHtml(user.Email || '—') + '</td>',
        '<td><span class="badge badge--info">' + escapeHtml(user.RoleName) + '</span></td>',
        '<td>' + statusBadge + '</td>',
        '<td>' + formatDate(user.LastLogin) + '</td>',
        '<td></td>'
    ].join('');

    const actionsCell = row.lastElementChild;

    if (canUpdate) {
        const editButton = document.createElement('button');
        editButton.type = 'button';
        editButton.className = 'row-action';
        editButton.textContent = 'Edit';
        editButton.addEventListener('click', () => openUserModal(root, user));
        actionsCell.appendChild(editButton);

        const resetButton = document.createElement('button');
        resetButton.type = 'button';
        resetButton.className = 'row-action';
        resetButton.textContent = 'Reset password';
        resetButton.addEventListener('click', () => openResetModal(user));
        actionsCell.appendChild(resetButton);
    }

    if (canDeactivate && user.UserID !== undefined) {
        const statusButton = document.createElement('button');
        statusButton.type = 'button';
        statusButton.className = 'row-action row-action--danger';
        statusButton.textContent = user.IsActive ? 'Deactivate' : 'Activate';
        statusButton.addEventListener('click', async () => {
            await setUserActive(root, user, !user.IsActive);
        });
        actionsCell.appendChild(statusButton);
    }

    return row;
}

/**
 * Kani nga action kay nag-toggle sa active status sa user account.
 */
async function setUserActive(root, user, isActive) {
    const confirmMessage = isActive
        ? 'Activate the account of ' + formatFullName(user) + '?'
        : 'Deactivate the account of ' + formatFullName(user) +
          '? They will no longer be able to sign in.';

    if (!window.confirm(confirmMessage)) {
        return;
    }

    try {
        await invoke('UserSetActive', {
            targetUserID: String(user.UserID),
            isActive: isActive ? 'true' : 'false'
        });
        showToast('success',
            'The account of ' + formatFullName(user) + ' has been ' +
            (isActive ? 'activated.' : 'deactivated.'));
        await reloadAll(root);
    } catch (error) {
        showToast('error', error.message);
    }
}

/**
 * Kani nga render kay nagdibu-on sa roles table.
 */
function renderRolesTable(root) {
    const body = root.querySelector('#rolesTableBody');
    if (!body) {
        return;
    }

    body.innerHTML = '';
    if (rolesData.length === 0) {
        body.innerHTML = '<tr><td colspan="6" class="data-table__empty">No roles found.</td></tr>';
        return;
    }

    rolesData.forEach((role) => {
        const row = document.createElement('tr');

        const nameCell = document.createElement('td');
        nameCell.textContent = role.RoleName;

        const descriptionCell = document.createElement('td');
        descriptionCell.textContent = role.Description || '—';

        const permissionCount = (role.PermissionCodes || []).length;

        row.innerHTML = [
            nameCell.outerHTML,
            descriptionCell.outerHTML,
            '<td>' + permissionCount + ' permission(s)</td>',
            '<td>' + role.ActiveUserCount + '</td>',
            '<td>' + (role.IsActive
                ? '<span class="badge badge--success">Active</span>'
                : '<span class="badge badge--error">Disabled</span>') + '</td>',
            '<td></td>'
        ].join('');

        if (hasPermission('settings.manage')) {
            const editButton = document.createElement('button');
            editButton.type = 'button';
            editButton.className = 'row-action';
            editButton.textContent = 'Edit';
            editButton.addEventListener('click', () => openRoleModal(root, role));
            row.lastElementChild.appendChild(editButton);
        }

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
    rolesData
        .filter((role) => role.IsActive || role.RoleID === selectedRoleID)
        .forEach((role) => {
            const option = document.createElement('option');
            option.value = String(role.RoleID);
            option.textContent = role.RoleName;
            select.appendChild(option);
        });
}

let selectedRoleID = null;

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
        text.innerHTML = '<span class="permissions-grid__code">' +
            escapeHtml(permission.PermissionCode) + '</span>' +
            '<span class="permissions-grid__hint">' + escapeHtml(permission.Description || '') + '</span>';

        label.appendChild(checkbox);
        label.appendChild(text);
        grid.appendChild(label);
    });
}

/**
 * Kani nga modal kay para sa paghimo (null) o pag-edit (user) sa user account.
 */
function openUserModal(root, user) {
    const modal = root.querySelector('#userModal');
    const title = root.querySelector('#userModalTitle');
    const passwordField = root.querySelector('#fieldPassword');
    const usernameField = root.querySelector('#fieldUsername');

    root.querySelector('#editUserID').value = user ? String(user.UserID) : '';
    root.querySelector('#txtFirstName').value = user ? user.FirstName || '' : '';
    root.querySelector('#txtLastName').value = user ? user.LastName || '' : '';
    root.querySelector('#txtMiddleName').value = user ? user.MiddleName || '' : '';
    root.querySelector('#txtUsername').value = user ? user.Username || '' : '';
    root.querySelector('#txtPassword').value = '';
    root.querySelector('#txtEmail').value = user ? user.Email || '' : '';

    // Kani nga role pre-select kay nagsiguro nga sakto ang dropdown value.
    selectedRoleID = user ? user.RoleID : null;
    fillRoleSelect(root);
    if (user) {
        root.querySelector('#selRole').value = String(user.RoleID);
    }

    // Kani nga toggles kay nagtago sa username/password fields sa edit mode.
    title.textContent = user ? 'Edit User Account' : 'New User Account';
    usernameField.style.display = user ? 'none' : '';
    passwordField.style.display = user ? 'none' : '';

    modal.classList.remove('u-hidden');
}

/**
 * Kani nga modal kay para sa admin password reset.
 */
function openResetModal(user) {
    resetTargetUserID = user.UserID;
    document.getElementById('resetUserInfo').textContent =
        'Resetting the password of ' + formatFullName(user) + ' (' + user.Username + ').';
    document.getElementById('txtNewPassword').value = '';
    document.getElementById('errorNewPassword').textContent = '';
    document.getElementById('resetModal').classList.remove('u-hidden');
}

/**
 * Kani nga modal kay para sa paghimo (null) o pag-edit (role) sa role.
 */
function openRoleModal(root, role) {
    const modal = root.querySelector('#roleModal');

    root.querySelector('#editRoleID').value = role ? String(role.RoleID) : '';
    root.querySelector('#txtRoleName').value = role ? role.RoleName || '' : '';
    root.querySelector('#txtRoleDescription').value = role ? role.Description || '' : '';

    // Kani nga guard kay nagpanalipod sa built-in Admin role sa edit mode.
    const isAdminRole = role && role.RoleID === 1;
    root.querySelector('#fieldRoleActive').style.display = isAdminRole ? 'none' : '';
    root.querySelector('#chkRoleActive').checked = role ? role.IsActive : true;

    const assignedCodes = new Set(role ? role.PermissionCodes || [] : []);
    root.querySelectorAll('#permissionsGrid input[type="checkbox"]').forEach((checkbox) => {
        checkbox.checked = assignedCodes.has(checkbox.value);
        checkbox.disabled = isAdminRole;
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
            root.querySelector(modalSelector).classList.add('u-hidden');
        });
    });

    // Kani nga overlay click kay para mo-close ang modal kung gi-click sa gawas.
    ['#userModal', '#resetModal', '#roleModal'].forEach((selector) => {
        root.querySelector(selector)?.addEventListener('click', (event) => {
            if (event.target === root.querySelector(selector)) {
                root.querySelector(selector).classList.add('u-hidden');
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

        // Kani nga client-side checks kay para sa maayo nga user experience ra;
        // ang authoritative validation kay gihapon sa C# backend.
        if (!payload.firstName || !payload.lastName || !payload.email || !payload.roleID) {
            showToast('warning', 'Please fill in all required fields.');
            return;
        }

        if (!isEdit && !payload.username) {
            showToast('warning', 'Please enter a username.');
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
                showToast('success',
                    'The user account has been created. Share the temporary password securely.');
            }

            root.querySelector('#userModal').classList.add('u-hidden');
            await reloadAll(root);
        } catch (error) {
            showToast('error', error.message);
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

        // Kani nga client-side rule kay parehas sa backend password policy.
        const policy = /^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[^a-zA-Z0-9]).{8,}$/;
        if (!policy.test(newPassword)) {
            errorLabel.textContent =
                'Password must contain an uppercase letter, a lowercase letter, a number, and a special character.';
            return;
        }

        try {
            await invoke('UserResetPassword', {
                targetUserID: String(resetTargetUserID),
                newPassword
            });
            showToast('success', 'The password has been reset.');
            root.querySelector('#resetModal').classList.add('u-hidden');
        } catch (error) {
            showToast('error', error.message);
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
            showToast('error', error.message);
        }
    });
}

/**
 * Kani nga helpers kay para sa safe display formatting.
 */
function formatFullName(user) {
    const middle = user.MiddleName ? ' ' + user.MiddleName.charAt(0).toUpperCase() + '.' : '';
    return escapeHtml((user.FirstName || '') + middle + ' ' + (user.LastName || ''));
}

function escapeHtml(value) {
    return String(value == null ? '' : value)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function formatDate(value) {
    // Kani nga parser kay nag-handle sa .NET JSON date format ("\/Date(ms)\/").
    if (!value) {
        return '—';
    }

    const match = /\/Date\((-?\d+)\)\//.exec(value);
    const ticks = match ? Number(match[1]) : NaN;
    const date = isNaN(ticks) ? new Date(value) : new Date(ticks);

    if (isNaN(date.getTime())) {
        return '—';
    }

    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString([], {
        hour: '2-digit', minute: '2-digit'
    });
}

/**
 * Kani nga destroy kay nag-tangtang sa listeners sa page.
 */
export function destroy() {
    searchHandler = null;
    usersData = [];
    rolesData = [];
    permissionsData = [];
    resetTargetUserID = null;
}
