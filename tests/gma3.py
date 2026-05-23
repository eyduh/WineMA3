from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from test_driver.machine import Machine

    machine: Machine = None  # type: ignore[assignment]

machine.start()
machine.wait_for_x()

machine.succeed("winema3-runner probe")

# Note: actual grandMA3 launch requires a valid installer in the prefix,
# which is not available in CI. This test verifies the package builds
# and the runner binary functions.
