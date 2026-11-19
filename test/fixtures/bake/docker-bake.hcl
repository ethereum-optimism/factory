target "selftest-bake" {
  context    = "test/fixtures/docker"
  dockerfile = "Dockerfile"
  tags       = ["example.invalid/selftest-bake:dev"]
}
