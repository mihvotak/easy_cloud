package com.sungeargames.easy_cloud

import androidx.core.content.FileProvider

/**
 * App-owned FileProvider. A concrete subclass avoids authority collisions with
 * libraries that also declare androidx.core.content.FileProvider.
 */
class EasyCloudFileProvider : FileProvider()
