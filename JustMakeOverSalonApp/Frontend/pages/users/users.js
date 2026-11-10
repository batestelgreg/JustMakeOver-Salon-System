// Kani nga script mo-handle sa pag-load sa users table ug pag-submit sa form
document.addEventListener("DOMContentLoaded", async () => {
    await loadUsersList();

    // Ablihi ang modal para sa pagdugang og user
    document.getElementById("btnOpenAddUser").addEventListener("click", () => {
        document.getElementById("userModal").style.display = "flex";
    });

    // Isira ang modal kung i-click ang cancel
    document.getElementById("btnCloseModal").addEventListener("click", () => {
        document.getElementById("userModal").style.display = "none";
    });

    // I-handle ang pag-submit sa bag-ong user
    document.getElementById("userForm").addEventListener("submit", async (e) => {
        e.preventDefault();

        const firstName = document.getElementById("txtFirstName").value;
        const lastName = document.getElementById("txtLastName").value;
        const username = document.getElementById("txtUsername").value;
        const email = document.getElementById("txtEmail").value;
        const password = document.getElementById("txtPassword").value;
        const roleID = parseInt(document.getElementById("selRole").value);

        // Tawgon ang C# backend bridge method gamit ang WebView2
        if (window.chrome && window.chrome.webview) {
            try {
                // Ipadala ang request sa C# bridge
                const response = await window.chrome.webview.hostObjects.bridge.CreateUser({
                    lastName: lastName,
                    firstName: firstName,
                    username: username,
                    password: password,
                    email: email,
                    roleID: roleID
                });

                alert("User account successfully created!");
                document.getElementById("userModal").style.display = "none";
                document.getElementById("userForm").reset();
                await loadUsersList();
            } catch (error) {
                alert("Failed to create user. Please check if the username or email is already taken.");
            }
        }
    });
});

// Function para makuha ug ipakita ang listahan sa mga users sa table
async function loadUsersList() {
    if (window.chrome && window.chrome.webview) {
        try {
            // Tawgon ang bridge operation para makuha ang users
            // O kaya gamita ang standard bridge routing kung giunsa nimo pag-setup sa router.js
            const result = await window.chrome.webview.hostObjects.bridge.LoadUsers();

            // Kon ang tubag kay JSON string, i-parse nato
            const users = typeof result === 'string' ? JSON.parse(result) : result;

            const tbody = document.querySelector("#usersTable tbody");
            tbody.innerHTML = "";

            if (users && Array.isArray(users)) {
                users.forEach(u => {
                    const tr = document.createElement("tr");
                    tr.innerHTML = `
                        <td>${u.UserID}</td>
                        <td>${u.LastName}, ${u.FirstName}</td>
                        <td>${u.Username}</td>
                        <td>${u.Email}</td>
                        <td><span class="badge">${u.RoleName}</span></td>
                        <td>${u.IsActive ? 'Active' : 'Inactive'}</td>
                        <td>
                            <button class="btn btn-sm btn-outline" onclick="editUser(${u.UserID})">Edit</button>
                        </td>
                    `;
                    tbody.appendChild(tr);
                });
            }
        } catch (err) {
            console.error("Error loading users list:", err);
        }
    }
}

// Function para sa pag-edit sa user (sunod nato i-implement kung gikinahanglan)
function editUser(userID) {
    console.log("Editing user ID:", userID);
}