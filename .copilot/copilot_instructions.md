## Changes to be made

### Patches

I want 2 more patches to be applied after the timer patch to better illustrate different versions runnning concurrently

Furthermore, I want a script that automates the rainbow deployment illustration, namely `make apply-load-sample-workflow`, applying the patch, and then, `skaffold run --profile helloworld-worker`

Another sciprt that removes all the patches so I can test it again

## UI

Since this is a rainbow deployment, I dont want labels like current target and depricated. Instead they should be different versions highlighted with different colors of the rainbow

I also want the illustration to feel smoother either by faster load, refresh rate, or increasing the loads that can run on a slot