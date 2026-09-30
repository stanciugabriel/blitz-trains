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
DISCLAIMER: Not all train trips are supported, so if you don't see it working, try with another trip. Most SBB-based trips work.

