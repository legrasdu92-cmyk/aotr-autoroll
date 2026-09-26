# Point d'entree : met a jour le programme si une nouvelle version existe, puis ouvre la fenetre.
& (Join-Path $PSScriptRoot 'mise-a-jour.ps1')
& (Join-Path $PSScriptRoot 'ui.ps1')
