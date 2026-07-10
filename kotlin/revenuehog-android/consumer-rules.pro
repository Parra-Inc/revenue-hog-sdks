# RevenueHog uses reflection only for the optional Play Billing listener
# helper. Keep the billing listener interface if the host app uses it.
-dontwarn com.android.billingclient.api.**
