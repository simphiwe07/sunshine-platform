# Container registry for the app image. Lives in the persistent foundation stack,
# so images survive the nightly lab-down.

resource "aws_ecr_repository" "app" {
  #checkov:skip=CKV_AWS_136:AES256 (AWS-managed key) instead of a KMS CMK - lab cost trade-off
  name = "${var.project}-app"

  # A tag can never be overwritten: :abc123 always means the same bytes,
  # so what was scanned is exactly what gets deployed.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true # second opinion next to the Trivy gate in CI
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Drop untagged layers (failed or replaced pushes) after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 15 newest images - enough to roll back"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 15
        }
        action = { type = "expire" }
      },
    ]
  })
}
