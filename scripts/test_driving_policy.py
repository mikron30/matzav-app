"""Compile and test the production driving decision code using only Python + JDK 17."""

from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    sources = [
        root / "android/app/src/main/java/com/mikron30/matzav/DrivingStatusPolicy.java",
        root / "test/native/DrivingStatusPolicyTest.java",
    ]
    with tempfile.TemporaryDirectory(prefix="matzav-driving-test-") as output:
        subprocess.run(
            ["java", "-m", "jdk.compiler/com.sun.tools.javac.Main", "--release", "17",
             "-Xlint:all", "-Werror", "-d", output, *map(str, sources)],
            check=True,
        )
        subprocess.run(
            ["java", "-cp", output, "com.mikron30.matzav.DrivingStatusPolicyTest"],
            check=True,
        )


if __name__ == "__main__":
    main()
