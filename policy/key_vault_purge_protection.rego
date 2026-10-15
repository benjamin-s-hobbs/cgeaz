package main

import rego.v1


# DenyKey Vault without purge protection is a security risk. 
#It can be deleted and then recreated with the same name, which can be used to exfiltrate secrets. 
#This policy gate rule prevents that.
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
