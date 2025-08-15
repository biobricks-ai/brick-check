#!/usr/bin/env python3
"""
Script to verify that the downloaded bricks have assets and that they load correctly.

This script:
1. Checks if `biobricks assets {name}` returns at least one file
2. Verifies that assets can load properly based on their file type:
   - Parquet files: Count rows
   - SQLite files: Count tables and rows  
   - HDT files: Count triples
3. Records failures in fail/failures.txt
"""

import os
import subprocess
import sys
import sqlite3
import biobricks as bb
from pathlib import Path
from typing import List, Optional
import pyarrow.parquet as pq
import rdflib


def run_command(cmd: List[str]) -> tuple[bool, str]:
    """Run a command and return success status and output."""
    try:
        result = subprocess.run(
            cmd, 
            capture_output=True, 
            text=True, 
            check=True,
            timeout=30
        )
        return True, result.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        error_msg = getattr(e, 'stderr', '') or str(e)
        return False, error_msg


def get_brick_assets(brick_name: str) -> tuple[bool, List[str]]:
    """Get the list of asset files for a brick."""
    success, output = run_command(['biobricks', 'assets', brick_name])
    if not success:
        return False, []
    
    # Parse the output to get file paths
    asset_files = []
    for line in output.split('\n'):
        line = line.strip()
        if line:
            asset_files.append(line)
    
    return len(asset_files) > 0, asset_files


def verify_parquet_file(file_path: str) -> tuple[bool, str]:
    """Verify a parquet file can be loaded and has data."""
    try:
        # Handle directory containing parquet files
        row_count = 0
        dataset = pq.ParquetDataset(file_path)
        for fragment in dataset.fragments:
            row_count += fragment.metadata.num_rows
        if row_count > 0:
            return True, f"Parquet file has {row_count} rows"
        else:
            return False, f"Parquet file is empty ({row_count} rows)"
    except Exception as e:
        return False, f"Failed to load parquet file: {str(e)}"


def verify_sqlite_file(file_path: str) -> tuple[bool, str]:
    """Verify a SQLite file can be opened and has data."""
    try:
        conn = sqlite3.connect(file_path)
        cursor = conn.cursor()
        
        # Get list of tables
        cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
        tables = cursor.fetchall()
        
        if not tables:
            conn.close()
            return False, "SQLite file has no tables"
        
        table_count = len(tables)
        total_rows = 0
        
        # Count rows in all tables
        for table_name, in tables:
            cursor.execute(f"SELECT COUNT(*) FROM `{table_name}`;")
            count = cursor.fetchone()[0]
            total_rows += count
        
        conn.close()
        
        if total_rows > 0:
            return True, f"SQLite file has {table_count} tables with {total_rows} total rows"
        else:
            return False, f"SQLite file has {table_count} tables but 0 rows"
            
    except Exception as e:
        return False, f"Failed to access SQLite file: {str(e)}"


def verify_hdt_file(file_path: str) -> tuple[bool, str]:
    """Verify an HDT file can be loaded and has triples."""
    try:
        # Try to load as RDF (HDT files are RDF format)
        g = rdflib.Graph()
        g.parse(file_path)
        
        triple_count = len(g)
        if triple_count > 0:
            return True, f"HDT file has {triple_count} triples"
        else:
            return False, "HDT file is empty (0 triples)"
            
    except Exception as e:
        return False, f"Failed to load HDT file: {str(e)}"


def verify_asset_file(file_path: str, brick_name: str) -> tuple[bool, str]:
    """Verify an asset file based on its extension."""
    file_path_lower = file_path.lower()
    brick_file = file_path.split(':')[0]
    brick_path = getattr(bb.assets(brick_name), brick_file)
    
    if file_path_lower.endswith('.parquet'):
        return verify_parquet_file(brick_path)
    elif file_path_lower.endswith(('.sqlite', '.sqlite3', '.db')):
        return verify_sqlite_file(brick_path)
    elif file_path_lower.endswith('.hdt'):
        return verify_hdt_file(brick_path)
    else:
        # For other file types, just check if file exists and has size > 0
        try:
            if os.path.getsize(file_path) > 0:
                return True, f"File exists and has size {os.path.getsize(file_path)} bytes"
            else:
                return False, "File is empty (0 bytes)"
        except Exception as e:
            return False, f"Failed to check file: {str(e)}"


def record_failure(brick_name: str, reason: str):
    """Record a brick failure to the failures file."""
    os.makedirs('fail', exist_ok=True)
    with open('fail/failures.txt', 'a') as f:
        f.write(f"{brick_name}\n")
    print(f"FAILED: {brick_name} - {reason}")


def verify_brick(brick_name: str) -> bool:
    """Verify a single brick. Returns True if successful, False if failed."""
    print(f"Verifying brick: {brick_name}")
    
    # Step 1: Check if assets exist and are accessible
    has_assets, asset_files = get_brick_assets(brick_name)
    if not has_assets:
        record_failure(brick_name, "No assets found or biobricks assets command failed")
        return False
    
    print(f"  Found {len(asset_files)} asset file(s)")
    
    # Step 2: Verify each asset file can load
    for asset_file in asset_files:
        success, message = verify_asset_file(asset_file, brick_name)
        if not success:
            record_failure(brick_name, f"Asset verification failed for {asset_file}: {message}")
            return False
        else:
            print(f"  ✓ {os.path.basename(asset_file)}: {message}")
    
    print(f"  ✓ {brick_name} verification passed")
    return True


def main():
    """Main verification script."""
    # Read the bricks list
    bricks_file = 'list/bricks.txt'
    if not os.path.exists(bricks_file):
        print(f"Error: {bricks_file} not found", file=sys.stderr)
        sys.exit(1)

    # Clear previous failures file if it exists
    if os.path.exists('fail/failures.txt'):
        os.remove('fail/failures.txt')

    # Read brick names
    with open(bricks_file, 'r') as f:
        brick_names = [line.strip() for line in f if line.strip() and not line.startswith('#')]

    print(f"Starting verification of {len(brick_names)} bricks...")
    
    success_count = 0
    failure_count = 0
    
    for brick_name in brick_names:
        if verify_brick(brick_name):
            success_count += 1
        else:
            failure_count += 1
    
    print(f"\nVerification complete:")
    print(f"  ✓ Successful: {success_count}")
    print(f"  ✗ Failed: {failure_count}")
    
    if failure_count > 0:
        print(f"  Failed bricks recorded in fail/failures.txt")
        sys.exit(1)
    else:
        print("  All bricks verified successfully!")


if __name__ == "__main__":
    main()
