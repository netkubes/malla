ExUnit.start()

# Configure Logger to reduce noise during tests
# Change to :info or :debug if you need to see more details
Logger.configure(level: :error)

# Compile and load test support modules in dependency order
support_dir = Path.join(__DIR__, "support")

# Load in correct dependency order
test_support_files = [
  "service1.ex",
  "plugin2_2.ex",
  "plugin2_1.ex",
  "service2.ex",
  "custom_tracer_plugin.ex",
  "tracer_service.ex",
  "status_test_service.ex",
  "call_test_service.ex",
  "custom_cb_in_service.ex"
]

Enum.each(test_support_files, fn file ->
  path = Path.join(support_dir, file)
  Code.require_file(path)
end)
