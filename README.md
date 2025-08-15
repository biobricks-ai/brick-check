# brick-check Testing Pipeline

A simple test script to verify that biobricks public bricks are downloaded + working correctly

1. Lists bricks that contain a dvc.lock file and are public
2. Installs those bricks using `biobricks install ${brick}`
3. Verifies that they are functional:
   a. Checks if the bricks have assets
   b. Checks if the bricks can be loaded using Python tools
   c. If they can be loaded, checks number of rows

