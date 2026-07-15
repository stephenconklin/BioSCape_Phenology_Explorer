"""
densify_flightboxes.py — Offline utility: densify LVIS_Flightboxes.geojson
edges so they render correctly in Leaflet.

Why this is needed
-------------------
LVIS_Flightboxes.geojson stores each flight box as a handful of corner
vertices in WGS84 (EPSG:4326). Each edge is a straight line in the box's
*native* UTM CRS (the CRS the LVIS/HLS data was actually processed in), but
a straight UTM line is NOT straight once converted to WGS84 lon/lat over a
long span (~100-150 km for these boxes). Leaflet renders GeoJSON polygons
as straight chords between consecutive vertices in screen space, so a
2-vertex edge cuts across that curve — producing a gap that's ~0 at the
vertices and grows toward the edge midpoint (confirmed empirically: ~180-460 m
north-biased gap on G5_14's north edge, ~320 m at the midpoint of G5_7's).

The raster overlay doesn't have this problem because
_regrid_to_mercator()/utm_to_latlon() in modules/datacube_io.py reproject
every pixel individually. This script applies the same fix to the vector
boundary: reproject each polygon to its region's true UTM CRS, segmentize
(insert points every SEGMENT_LENGTH_M along each edge, still straight in
UTM), then reproject back to WGS84. The result traces the same curve the
raster follows.

Per-region CRS is auto-detected from each region's own datacube (mirrors
detect_crs_epsg() in datacube_io.py) rather than assumed, since G5_17 is
UTM Zone 35S while every other current region is Zone 34S.

Usage
-----
    python tools/densify_flightboxes.py
    python tools/densify_flightboxes.py --segment-length 250
    python tools/densify_flightboxes.py --output shapefiles/LVIS_Flightboxes_densified.geojson
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import geopandas as gpd
import shapely

from modules.datacube_io import discover_regions, get_dataset, detect_crs_epsg
import config


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        default=str(Path(config.SHAPEFILE_PATHS).resolve()),
        help="Source flightbox GeoJSON (default: config.SHAPEFILE_PATHS)",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Output path (default: <input_stem>_densified.geojson, next to input)",
    )
    parser.add_argument(
        "--segment-length",
        type=float,
        default=500.0,
        metavar="METERS",
        help="Max segment length in the projected CRS (default: 500 m)",
    )
    args = parser.parse_args()

    in_path = Path(args.input)
    out_path = Path(args.output) if args.output else in_path.with_name(
        in_path.stem + "_densified" + in_path.suffix
    )

    print(f"Reading {in_path} ...")
    gdf = gpd.read_file(in_path)
    if gdf.crs is None or gdf.crs.to_epsg() != 4326:
        gdf = gdf.to_crs(epsg=4326)

    print("Discovering regions to determine each flightbox's true CRS ...")
    regions = discover_regions(config.DATACUBE_ROOT)

    epsg_cache: dict[str, int] = {}

    def region_epsg(region_id: str) -> int:
        if region_id not in epsg_cache:
            if region_id not in regions:
                print(
                    f"  WARNING: box_nr {region_id!r} has no matching discovered "
                    f"region — falling back to config.DATACUBE_CRS_EPSG"
                )
                epsg_cache[region_id] = config.DATACUBE_CRS_EPSG
            else:
                ds = get_dataset(regions[region_id])
                epsg_cache[region_id] = detect_crs_epsg(ds)
        return epsg_cache[region_id]

    new_geoms = []
    for _, row in gdf.iterrows():
        box_nr = row["box_nr"]
        epsg = region_epsg(box_nr)
        geom_utm = gpd.GeoSeries([row.geometry], crs=4326).to_crs(epsg).iloc[0]
        geom_utm_dense = shapely.segmentize(geom_utm, max_segment_length=args.segment_length)
        geom_wgs84_dense = gpd.GeoSeries([geom_utm_dense], crs=epsg).to_crs(4326).iloc[0]
        new_geoms.append(geom_wgs84_dense)
        n_before = len(list(row.geometry.exterior.coords)) if row.geometry.geom_type == "Polygon" else "multi"
        n_after = len(list(geom_wgs84_dense.exterior.coords)) if geom_wgs84_dense.geom_type == "Polygon" else "multi"
        print(f"  {box_nr}: EPSG:{epsg}, vertices {n_before} -> {n_after}")

    gdf_out = gdf.copy()
    gdf_out["geometry"] = new_geoms
    gdf_out = gdf_out.set_crs(epsg=4326, allow_override=True)

    print(f"Writing {out_path} ...")
    gdf_out.to_file(out_path, driver="GeoJSON")
    print("Done.")


if __name__ == "__main__":
    main()
