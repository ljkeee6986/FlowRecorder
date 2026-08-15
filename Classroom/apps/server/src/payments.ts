import type { Order, PaymentProviderName } from "@flowrecorder/contracts";

export interface CreatePaymentInput {
  order: Order;
  returnUrl: string;
  notifyUrl: string;
}

export interface PaymentIntent {
  provider: PaymentProviderName;
  providerReference: string;
  checkoutUrl?: string;
  qrCodePayload?: string;
}

export interface PaymentProvider {
  readonly name: PaymentProviderName;
  createPayment(input: CreatePaymentInput): Promise<PaymentIntent>;
  verifyNotification(payload: unknown, headers: Record<string, string>): Promise<string>;
  refund(order: Order, reason: string): Promise<void>;
}

class DisabledPaymentProvider implements PaymentProvider {
  constructor(readonly name: PaymentProviderName) {}

  async createPayment(): Promise<PaymentIntent> {
    throw new Error(`${this.name} payment is reserved but disabled in Classroom 0.1`);
  }

  async verifyNotification(): Promise<string> {
    throw new Error(`${this.name} payment notifications are disabled`);
  }

  async refund(): Promise<void> {
    throw new Error(`${this.name} refunds are disabled`);
  }
}

export const paymentProviders: Record<PaymentProviderName, PaymentProvider> = {
  wechat: new DisabledPaymentProvider("wechat"),
  alipay: new DisabledPaymentProvider("alipay")
};
