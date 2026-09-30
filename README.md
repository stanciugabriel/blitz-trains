## To use the server-based features of this app you need run locally the following services:
- https://github.com/stevensun369/sbb-rt
- https://github.com/stevensun369/sbb-formation

For both projects you need a .env file where you have to add the token like this "TOKEN=....." 
The token for both can be provided for free here:
- for sbb-formation: https://api-manager.opentransportdata.swiss/portal/catalogue-products/tedp_formation_service_api-1
- for sbb-rt: https://api-manager.opentransportdata.swiss/portal/catalogue-products/tedp_gtfs_rt-1

You can then run the sbb-formation service with `go run main.go` and the sbb-rt with `go run .` in the root of the project.

Finally, make sure the PC that runs these services locally is on the same network as the phone running the app. Then, find your 
machine's IP within the network and add it in the iOS app in the settings page.

That's it! You can now see train formations, and get real time updates. 
# DISCLAIMER: 
Not all train trips are supported, so if you don't see it working, try with another trip. Most SBB-based trips work. The swiss opentransport website publishes new GTFS files bi-weekly. When they do that, the old ones will not work anymore. That means that the one in the repository will be stale by the time this project is opened. This is why, most probably real time delays, won't be working in a few days. We didn't manage to make a system that auto updates the GTFS files yet. The GTFS files are encapsulated in `mini_feed.sqlite`.

Thanks for taking the time to check our project.

