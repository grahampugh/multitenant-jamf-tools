#!/usr/bin/env python3

# This script initializes a new Jamf Pro instance using the Jamf Pro API.
# It checks the instance status and if it requires initialization, it sends the necessary data to initialize it.
# The script accepts command line arguments for the instance URL, admin username, password, and activation code.
# It also includes error handling and logging for better debugging and user feedback.

# note: This script is designed to be run in a Python 3 environment. It required the requests library.
# It can be installed using pip:
# pip install requests
# or
# pip3 install requests


import argparse
import json
import logging
import sys
import time
import secrets
import string

from typing import Optional
from urllib.parse import urlparse

import requests

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


class JamfInitializer:
    def __init__(self, instance_url: str):
        """
        Initialize the JamfInitializer with the Jamf Pro instance URL.

        Args:
            instance_url (str): The base URL of the Jamf Pro instance
                              (e.g., 'https://myjamfinstance.jamfcloud.com')
        """
        self.base_url = instance_url.rstrip("/")
        self.session = requests.Session()
        # Disable SSL warning for self-signed certificates if needed
        # requests.packages.urllib3.disable_warnings()

    def check_instance_status(self) -> Optional[dict]:
        """
        Check the health status of the Jamf Pro instance.

        Returns:
            dict: The parsed health check response or None if request fails
        """
        try:
            response = self.session.get(
                f"{self.base_url}/api/startup-status", timeout=30
            )
            response.raise_for_status()

            # Clean up the response - replace HTML encoded quotes
            cleaned_response = response.text.replace("&quot;", '"')
            return json.loads(cleaned_response)

        except requests.exceptions.RequestException as e:
            logger.error("Error checking instance status: %s", str(e))
            return None
        except (json.JSONDecodeError, IndexError) as e:
            logger.error("Error parsing health check response: %s", str(e))
            return None

    def initialize_instance(
        self,
        admin_username: str,
        admin_password: str,
        activation_code: str,
        institution_name: str = "Jamf",
        email: str = "default@example.com",
    ) -> bool:
        """
        Initialize the Jamf Pro instance using the API.

        Args:
            admin_username (str): The username for the initial admin account
            admin_password (str): The password for the initial admin account
            activation_code (str): The activation code for the instance
            institution_name (str): The name of the institution (default: "Jamf")
            email (str): The email address for the initial admin account

        Returns:
            bool: True if initialization was successful, False otherwise
        """
        try:
            payload = {
                "jssUrl": self.base_url,
                "username": admin_username,
                "password": admin_password,
                "activationCode": activation_code,
                "eulaAccepted": True,
                "institutionName": institution_name,
                "email": email,
            }
            # Send initialization request

            response = self.session.post(
                f"{self.base_url}/api/v1/system/initialize",
                json=payload,
                headers={"Content-Type": "application/json"},
                timeout=30,
            )
            response.raise_for_status()
            return True

        except requests.exceptions.RequestException as e:
            logger.error("Error initializing instance: %s", str(e))
            return False


def validate_url(url: str) -> str:
    """
    Validate the provided URL format.

    Args:
        url (str): URL to validate

    Returns:
        str: Validated URL

    Raises:
        argparse.ArgumentTypeError: If URL is invalid
    """
    try:
        result = urlparse(url)
        if all([result.scheme, result.netloc]):
            return url
        raise ValueError
    except ValueError as exc:
        raise argparse.ArgumentTypeError(
            f"Invalid URL format: {url}. URL must include scheme (e.g., https://)"
        ) from exc


def generate_secure_password() -> str:
    """
    Generate a secure password that meets Jamf Pro requirements.
    Returns a 16-character password with letters, numbers, and at least one hyphen or underscore.
    """
    # Basic character set
    chars = string.ascii_letters + string.digits

    # Generate first 31 characters
    password = [secrets.choice(chars) for _ in range(31)]

    # Ensure at least one hyphen or underscore by adding it at a random position
    symbol = secrets.choice('-')
    insert_pos = secrets.randbelow(32)  # Random position 0-31
    password.insert(insert_pos, symbol)

    return ''.join(password)


def parse_arguments() -> argparse.Namespace:
    """
    Parse and validate command line arguments.

    Returns:
        argparse.Namespace: Parsed command line arguments
    """
    parser = argparse.ArgumentParser(
        description="Initialize a new Jamf Pro instance",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Example usage:
  %(prog)s -u https://myjamfinstance.jamfcloud.com -a jamfadmin -c MyActivationCode
  %(prog)s --url https://myjamfinstance.jamfcloud.com --username jamfadmin --password MySecurePassword123 -activationcode MyActivationCode
        """,
    )

    parser.add_argument(
        "-u",
        "--url",
        required=True,
        type=validate_url,
        help="Jamf Pro instance URL (e.g., https://myjamfinstance.jamfcloud.com)",
    )

    parser.add_argument(
        "-a", "--username", required=True, help="Admin username for initialization"
    )

    parser.add_argument(
        "-p", "--password", required=False, help="Admin password for initialization, random if not provided"
    )

    parser.add_argument(
        "-c",
        "--activationcode",
        required=True,
        help="Activation Code for initialization",
    )

    parser.add_argument(
        "-i",
        "--institution-name",
        default="Jamf",
        help="Institution name for initialization (default: Jamf)",
    )

    parser.add_argument(
        "-e", "--email", required=False, help="Email address for initialization"
    )

    parser.add_argument(
        "--max-attempts",
        type=int,
        default=10,
        help="Maximum number of health check attempts (default: 10)",
    )

    parser.add_argument(
        "--attempt-delay",
        type=int,
        default=30,
        help="Delay in seconds between attempts (default: 30)",
    )

    return parser.parse_args()


def main():
    # Parse command line arguments
    args = parse_arguments()

    if not args.password:
        generated_password = generate_secure_password()
        args.password = generated_password
        logger.info("Generated secure random password:")
        print(f"\nGenerated Password: {generated_password}\n")
        logger.info("Please save this password in a secure location!")

    initializer = JamfInitializer(args.url)

    logger.info(f"Starting initialization process for {args.url}")

    for attempt in range(args.max_attempts):
        logger.info(
            f"Checking instance status (attempt {attempt + 1}/{args.max_attempts})"
        )

        status = initializer.check_instance_status()
        if status is None:
            logger.warning("Unable to get instance status, will retry...")
            time.sleep(args.attempt_delay)
            continue

        logger.info(f"Health check status: {status}")

        if status.get("setupAssistantNecessary") is True:
            logger.info("Instance requires initialization, proceeding...")

            if initializer.initialize_instance(
                args.username,
                args.password,
                args.activationcode,
                args.institution_name,
                args.email,
            ):
                logger.info("Instance initialization successful!")
                sys.exit(0)
            else:
                logger.error("Instance initialization failed!")
                sys.exit(1)
        else:
            logger.info("Instance is already initialized or in an unexpected state")
            sys.exit(0)

        time.sleep(args.attempt_delay)

    logger.error(
        f"Maximum attempts ({args.max_attempts}) reached without successful initialization"
    )
    sys.exit(1)


if __name__ == "__main__":
    main()
