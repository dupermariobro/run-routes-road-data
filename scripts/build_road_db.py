#!/usr/bin/env python3
"""Build one region's roads-only major-road SQLite file from osmium GeoJSON sequences.

The tables, 12-point geometry chunks, and little-endian float32 coordinate blobs
match scripts/build-local-road-safety-index.py in the Run Routes iOS repo, so the
app's SQLiteLocalRoadSafetyIndex reads these files without changes
(road_schema_version run-routes-road-safety-v1).
"""

import argparse
import json
import sqlite3
import struct
from pathlib import Path


ROAD_CLASSES = {
    "motorway",
    "motorway_link",
    "trunk",
    "trunk_link",
    "primary",
    "primary_link",
}


def line_strings(geometry):
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates", [])
    if geometry_type == "LineString":
        yield coordinates
    elif geometry_type == "MultiLineString":
        yield from coordinates


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--geojsonseq", required=True, type=Path)
    parser.add_argument("--region-id", required=True)
    parser.add_argument("--region-name", required=True)
    parser.add_argument("--data-version", required=True)
    parser.add_argument("--data-date", required=True)
    args = parser.parse_args()

    if args.database.exists():
        args.database.unlink()
    database = sqlite3.connect(args.database)
    database.executescript(
        """
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE road_ways (
          id INTEGER PRIMARY KEY,
          osm_id TEXT,
          name TEXT,
          ref TEXT,
          classification TEXT NOT NULL,
          maxspeed TEXT,
          foot TEXT
        );
        CREATE TABLE road_geometry_chunks (
          id INTEGER PRIMARY KEY,
          way_id INTEGER NOT NULL,
          coordinates BLOB NOT NULL
        );
        CREATE VIRTUAL TABLE road_geometry_rtree USING rtree(
          id, min_lon, max_lon, min_lat, max_lat
        );
        """
    )

    way_id = 0
    segment_id = 0
    chunk_id = 0
    west, south, east, north = 180.0, 90.0, -180.0, -90.0
    with args.geojsonseq.open("r", encoding="utf-8") as source:
        for raw_line in source:
            line = raw_line.lstrip("\x1e").strip()
            if not line:
                continue
            feature = json.loads(line)
            properties = feature.get("properties") or {}
            classification = properties.get("highway")
            if classification not in ROAD_CLASSES:
                continue
            geometries = list(line_strings(feature.get("geometry") or {}))
            if not geometries:
                continue
            way_id += 1
            database.execute(
                """
                INSERT INTO road_ways
                  (id, osm_id, name, ref, classification, maxspeed, foot)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    way_id,
                    str(feature.get("id", "")),
                    properties.get("name"),
                    properties.get("ref"),
                    classification,
                    properties.get("maxspeed"),
                    properties.get("foot"),
                ),
            )
            for coordinates in geometries:
                points = [point[:2] for point in coordinates if len(point) >= 2]
                segment_id += max(0, len(points) - 1)
                chunk_start = 0
                while chunk_start < len(points) - 1:
                    chunk = points[chunk_start:chunk_start + 12]
                    if len(chunk) < 2:
                        break
                    chunk_id += 1
                    flattened = [value for point in chunk for value in point]
                    database.execute(
                        """
                        INSERT INTO road_geometry_chunks (id, way_id, coordinates)
                        VALUES (?, ?, ?)
                        """,
                        (
                            chunk_id,
                            way_id,
                            struct.pack(f"<{len(flattened)}f", *flattened),
                        ),
                    )
                    longitudes = [point[0] for point in chunk]
                    latitudes = [point[1] for point in chunk]
                    database.execute(
                        """
                        INSERT INTO road_geometry_rtree
                          (id, min_lon, max_lon, min_lat, max_lat)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        (
                            chunk_id,
                            min(longitudes),
                            max(longitudes),
                            min(latitudes),
                            max(latitudes),
                        ),
                    )
                    west = min(west, min(longitudes))
                    east = max(east, max(longitudes))
                    south = min(south, min(latitudes))
                    north = max(north, max(latitudes))
                    chunk_start += len(chunk) - 1
            if way_id % 5_000 == 0:
                database.commit()

    if way_id == 0:
        raise SystemExit(f"{args.region_id}: no major-road ways found")

    metadata = {
        "region_id": args.region_id,
        "region_name": args.region_name,
        "west": repr(west),
        "south": repr(south),
        "east": repr(east),
        "north": repr(north),
        "road_schema_version": "run-routes-road-safety-v1",
        "road_data_version": args.data_version,
        "road_data_date": args.data_date,
        "road_source": "OpenStreetMap",
        "road_license": "ODbL",
        "road_attribution": "© OpenStreetMap contributors",
        "road_extract_provider": "Geofabrik",
        "road_way_count": str(way_id),
        "road_segment_count": str(segment_id),
        "road_chunk_count": str(chunk_id),
    }
    database.executemany(
        "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)",
        metadata.items(),
    )
    database.execute("ANALYZE")
    database.commit()
    database.execute("VACUUM")
    database.close()
    print(json.dumps({"ways": way_id, "segments": segment_id, "chunks": chunk_id}))


if __name__ == "__main__":
    main()
