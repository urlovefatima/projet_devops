run "noms_corrects_en_dev" {
  command = plan

  assert {
    condition     = output.storage_name == "cloud-project-dev-storage"
    error_message = "Le nom du bucket doit être <project>-<env>-storage."
  }

  assert {
    condition     = output.database_name == "cloud-project-dev-table"
    error_message = "Le nom de la table doit être <project>-<env>-table."
  }
}

run "environnement_invalide_refuse" {
  command = plan

  variables {
    environment = "staging"
  }

  expect_failures = [var.environment]
}
