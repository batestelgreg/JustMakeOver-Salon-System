# CONTRACTS: Leader and Module Developers

**Rule #1:** No module developer edits shared files. If a change is needed, message the leader.

## Ownership

|-------------------------------------------------------------------------------------|-------------------------|
| Territory                                                                           |          Owner          |
|-------------------------------------------------------------------------------------|-------------------------|
| Core, FrontendBridge.cs, Bridge/Modules, assets/js/core, assets/js/routes, Database |       Leader            |
|-------------------------------------------------------------------------------------|-------------------------|
| JustMakeOverSalonApp.Requisition / Inventory / Purchasing / Delivery                | That module's developer |
|-------------------------------------------------------------------------------------|-------------------------|
| Frontend/pages/<module>/                                                            | Module developer        |
|-------------------------------------------------------------------------------------|-------------------------|

The `.github/CODEOWNERS` file enforces this on GitHub.

## Contracts from Core
- `IModuleOperations`, `OperationRegistry`, `IOperationContext` (JustMakeOverSalonApp.Core/Bridge)
- `PermissionCodes` (JustMakeOverSalonApp.Core/Contracts): use the constants, not raw strings
- `SqlConnectionFactory`, `BusinessException` (for English validation messages)

## Module rules
- Reference Core only, never another module.
- Bridge operations: `<Module><Action>`, registered in your own `Operations/<Module>Module.cs`.
- Stored procedures: `usp<Module><Action>`.
- Migrations: `Database/Migrations/V###_<Module>_<Description>.sql`. Ask the leader for a number. Never edit a migration that has already been applied.
- Branches: `feature/<module>`. Open PRs into `main`.
- Validation messages: English. Code comments: short Cebuano.

## If a shared file needs to change
1. Message the leader.
2. The leader creates a `contract/...` PR and merges it.
3. Developer: run `git merge origin/main` on your branch.