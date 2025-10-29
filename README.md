# ssl-alert-automation

# **Architecture**

<img width="340" height="716" alt="image" src="https://github.com/user-attachments/assets/7b10e25c-ebfd-46a0-a406-8d08177ae401" />


Here’s your content rewritten in **Markdown format**:

***

# **Architecture: The Moving Parts**

*   **Azure Key Vault** — Source of truth for secrets/certificates.
*   **Azure Logic App** — Orchestrates the daily job and email.
*   **Office 365 (Outlook) connector** — Sends the notification email.
*   **System‑assigned Managed Identity (MI)** — Secure, passwordless access from Logic App to Key Vault.

***

## **Prerequisites**

*   **Az PowerShell modules** (`Az.Accounts`, `Az.Resources`, `Az.KeyVault`) installed for your user scope.
*   **Owner/Contributor** role on the target subscription/resource group and rights to assign Key Vault access (RBAC or access policies).
*   A **sender mailbox** (e.g., service account) to authorize the Office 365 connector in the Logic App.

***

## **How the Automation Works (High Level)**

1.  **Daily trigger:** A Recurrence trigger fires once per day (set to India Standard Time in the sample).
2.  **List secrets:** The Logic App calls the Key Vault connector to list secrets.
3.  **Filter expiring soon:** For each secret, the workflow checks `validityEndTime` and flags those expiring in ≤ 30 days.
4.  **Build a table:** It constructs an HTML table (name + expiration date) for all matches.
5.  **Send email:**
    *   If there are matches, it emails a summary: **“SSL Certification Expiration Summary”**.
    *   If none, it emails a clean bill of health: **“No SSL certificates are expiring in the next 30 days.”**

