import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_ROOT = PROJECT_ROOT / "terraform"
ENVIRONMENTS_ROOT = TERRAFORM_ROOT / "environments"

ENVIRONMENT_DIRECTORIES = (
    ENVIRONMENTS_ROOT / "primary_us_east_1",
    ENVIRONMENTS_ROOT / "secondary_us_west_2",
    ENVIRONMENTS_ROOT / "global",
)


def terraform_executable() -> str:
    executable = shutil.which("terraform")
    if executable is None:
        pytest.fail("Terraform executable is not available in PATH")
    return executable


def run_command(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=180,
    )


@pytest.mark.parametrize("environment_directory", ENVIRONMENT_DIRECTORIES)
def test_environment_has_main_configuration(environment_directory: Path):
    assert environment_directory.is_dir()
    assert (environment_directory / "main.tf").is_file()
    assert (environment_directory / "variables.tf").is_file()
    assert (environment_directory / "outputs.tf").is_file()


def test_terraform_formatting():
    terraform = terraform_executable()

    result = run_command(
        [terraform, "fmt", "-check", "-recursive", str(TERRAFORM_ROOT)],
        PROJECT_ROOT,
    )

    assert result.returncode == 0, (
        "Terraform formatting check failed.\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )


@pytest.mark.parametrize("environment_directory", ENVIRONMENT_DIRECTORIES)
def test_terraform_environment_initializes_and_validates(environment_directory: Path):
    terraform = terraform_executable()

    init_result = run_command(
        [terraform, "init", "-backend=false", "-input=false", "-no-color"],
        environment_directory,
    )
    assert init_result.returncode == 0, (
        f"terraform init failed in {environment_directory.name}.\n"
        f"stdout:\n{init_result.stdout}\n"
        f"stderr:\n{init_result.stderr}"
    )

    validate_result = run_command(
        [terraform, "validate", "-no-color"],
        environment_directory,
    )
    assert validate_result.returncode == 0, (
        f"terraform validate failed in {environment_directory.name}.\n"
        f"stdout:\n{validate_result.stdout}\n"
        f"stderr:\n{validate_result.stderr}"
    )


def test_primary_environment_has_active_capacity_and_region():
    main_tf = (ENVIRONMENTS_ROOT / "primary_us_east_1" / "main.tf").read_text(
        encoding="utf-8"
    )

    assert 'region = var.aws_region' in main_tf
    assert 'min_size          = 2' in main_tf
    assert 'desired_capacity  = 2' in main_tf
    assert 'multi_az                = true' in main_tf
    assert 'is_read_replica         = false' in main_tf


def test_secondary_environment_has_warm_standby_configuration():
    main_tf = (ENVIRONMENTS_ROOT / "secondary_us_west_2" / "main.tf").read_text(
        encoding="utf-8"
    )

    assert 'vpc_cidr                  = "10.1.0.0/16"' in main_tf
    assert 'min_size          = 0' in main_tf
    assert 'desired_capacity  = 0' in main_tf
    assert 'is_read_replica         = true' in main_tf
    assert 'replicate_source_db     = data.terraform_remote_state.primary.outputs.rds_arn' in main_tf


def test_global_environment_has_multi_region_failover():
    main_tf = (ENVIRONMENTS_ROOT / "global" / "main.tf").read_text(
        encoding="utf-8"
    )

    assert 'health_check_path = "/health"' in main_tf
    assert 'request_interval  = 10' in main_tf
    assert 'failure_threshold = 3' in main_tf
    assert 'origin_id   = "primary-alb-us-east-1"' in main_tf
    assert 'origin_id   = "secondary-alb-us-west-2"' in main_tf
    assert 'status_codes = [500, 502, 503, 504]' in main_tf
