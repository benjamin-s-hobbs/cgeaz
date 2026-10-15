package main

import rego.v1


# Deny: Public IP on a network interface
# Requirements>> 1) Correct alias paths 2) Effect parameterized (audit / deny)
# >>>>>>>>>>>>>> 3) Mapping in CONTROLS.md 4) A blast-radius comment block

broad_roles := {"Owner", "Contributor"}

deny contains msg if {
	some rc in input.resource_changes
	rc.type == "azurerm_role_assignment"
	rc.change.actions[_] != "delete"
	rc.change.after.role_definition_name in broad_roles
	msg := sprintf("%s: %s at any scope is not a whitelist — use a granular role", 
	[rc.address, rc.change.after.role_definition_name])
}

